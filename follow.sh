#!/bin/bash
# Keeps the VM on what Terraform last set (docs/deploy.md §8). It waits on the instance's metadata, and when its
# deployment-env changes (a new release, a new setting), or the channel it names moves to another release (checked every
# few minutes), it moves onto it with `demiurge-admin release`, which exports
# Convex first and fails unless everything is healthy after. A failed move goes back to what ran before, unless Convex's
# own image moved (it migrates its data, so that's restored by hand from the export).
#
# Every change it sees gets a guest attribute, demiurge/status, for a deploy to wait on: "<state> <id> <release>…", where
# <id> is the start of the sha256 of the deployment-env it's about, so a deploy never mistakes an older answer for its own.
# <state> is releasing, released, rolled-back, failed or not-set-up.
#
# startup.sh fetches this from the metadata and sources it; `follow.sh follow` is the service.
set -euo pipefail

METADATA=http://metadata.google.internal/computeMetadata/v1/instance
DIR=/srv/demiurge
LOG=$DIR/follow.log
SELF=/usr/local/lib/demiurge-follow.sh
# Held while moving, and by the start script while it sets up, so the two never change the VM at once.
LOCK=/run/demiurge-release.lock

attribute() { curl -fsS -H "Metadata-Flavor: Google" "$METADATA/attributes/$1"; }

resolve() {
  local from="$1" to="$2" version harness web releases digests
  version=$(setting "$from" RELEASE)
  harness=$(setting "$from" HARNESS_IMAGE)
  web=$(setting "$from" WEB_IMAGE)
  releases=$(setting "$from" RELEASES)
  install -m 600 "$from" "$to"
  if [ -n "$(setting "$from" CHANNEL)" ]; then
    version=$(channel_release "$from") || return 1
    harness="" web=""
  fi
  if [ -z "$harness" ]; then
    harness="$(setting "$from" IMAGE_REGISTRY)/demiurge-harness:$version"
    web="$(setting "$from" IMAGE_REGISTRY)/demiurge-web:$version"
    if [ -n "$releases" ]; then
      digests=$(release_digests "$releases" "$version") || return 1
      harness="${harness%:*}@${digests% *}" web="${web%:*}@${digests#* }"
    fi
  fi
  harness=$(tag_to_digest "$harness") && web=$(tag_to_digest "$web") || return 1
  [ -z "$version" ] || same_digests_as_before "$version" "$harness $web" || return 1
  settings_name "$from" "$version" "$harness" "$web" ||
    printf 'RELEASE="%s"\nHARNESS_IMAGE="%s"\nWEB_IMAGE="%s"\n' "$version" "$harness" "$web" >> "$to"
}
setting() { sed -n "s/^ *$2=\"\(.*\)\"$/\1/p" "$1"; }
channel_release() {
  local channel version
  channel=$(setting "$1" CHANNEL)
  version=$(gcloud storage cat "$(setting "$1" CHANNELS)/$channel" 2>>"$LOG" | tr -d '[:space:]') || return 1
  [[ "$version" =~ ^v[0-9][0-9.]*$ ]] || { echo "$(date -Is) channel $channel names \"$version\", not a release" >> "$LOG"; return 1; }
  echo "$version"
}
release_digests() {
  gcloud storage cat "$1/$2/release.json" 2>>"$LOG" | python3 -c 'import json, re, sys
release = json.load(sys.stdin)
digests = [release[image].rpartition("@")[2] for image in ("harness", "web")]
if release.get("version") != sys.argv[1] or not all(re.fullmatch("sha256:[0-9a-f]{64}", d) for d in digests):
    sys.exit("it names another release, or an image without a digest")
print(*digests)' "$2" 2>>"$LOG" || { echo "$(date -Is) couldn't read $2's digests from $1/$2/release.json" >> "$LOG"; return 1; }
}
tag_to_digest() {
  local digest
  if [[ "$1" == *@sha256:* ]]; then echo "$1"; return; fi
  digest=$(gcloud artifacts docker images describe "$1" --format='value(image_summary.digest)' 2>>"$LOG") || return 1
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "$(date -Is) $1 has no digest in its registry" >> "$LOG"; return 1; }
  echo "${1%:*}@$digest"
}
same_digests_as_before() {
  local record="$DIR/releases/$1"
  if [ -f "$record" ] && [ "$(cat "$record")" != "$2" ]; then
    echo "$(date -Is) REFUSED $1: it now names $2, but this VM took it as $(cat "$record"); staying on what runs" | tee -a "$LOG" >&2
    return 1
  fi
  mkdir -p "$DIR/releases"
  echo "$2" > "$record"
}
settings_name() { [ "$2" = "$(setting "$1" RELEASE)" ] && [ "$3" = "$(setting "$1" HARNESS_IMAGE)" ] && [ "$4" = "$(setting "$1" WEB_IMAGE)" ]; }
id_of() { sha256sum "$1" | cut -c1-12; }
status() {   # state, the env file it's about, then words: newest wins
  local line
  line="$1 $(id_of "$2") ${*:3}"
  curl -fsS -X PUT -H "Metadata-Flavor: Google" --data "$line" "$METADATA/guest-attributes/demiurge/status" >/dev/null || true
  echo "$(date -Is) $line" >> "$LOG"
}
release_of() {
  # shellcheck source=/dev/null
  (set -a; . "$1"; set +a; echo "${RELEASE:-${HARNESS_IMAGE##*[:@]}}")
}
convex_image() { sed -n 's|^ *image: \(ghcr.io/convex/convex-backend@sha256:[0-9a-f]*\)$|\1|p' /opt/demiurge/infra/compose/docker-compose.yml 2>/dev/null || true; }

# The release's images and the kit inside its harness image (demiurge-admin, the Compose file), for an env file. Each
# step says if it failed: callers use this in an `if`, where bash ignores `set -e`.
fetch_kit() {
  local env="$1"
  (
    set -a
    # shellcheck source=/dev/null
    . "$env" || exit 1
    set +a
    gcloud auth configure-docker "${HARNESS_IMAGE%%/*}" --quiet >/dev/null || exit 1
    docker pull -q "$HARNESS_IMAGE" >/dev/null || exit 1
    docker pull -q "$WEB_IMAGE" >/dev/null || exit 1
    rm -rf /opt/demiurge.next
    kit=$(docker create "$HARNESS_IMAGE") || exit 1
    docker cp "$kit:/opt/demiurge" /opt/demiurge.next || { docker rm "$kit" >/dev/null; exit 1; }
    docker rm "$kit" >/dev/null || true
  ) || return 1
  rm -rf /opt/demiurge.old
  if [ -d /opt/demiurge ]; then mv /opt/demiurge /opt/demiurge.old || return 1; fi
  mv /opt/demiurge.next /opt/demiurge || return 1
  rm -rf /opt/demiurge.old
  ln -sf /opt/demiurge/infra/admin/demiurge-admin /usr/local/bin/demiurge-admin || return 1
}

images_of() {
  # shellcheck source=/dev/null
  (set -a; . "$1"; set +a; echo "$HARNESS_IMAGE"; echo "$WEB_IMAGE") 2>/dev/null || true
}

tidy() {
  local keep ref repo id
  keep=$({ images_of "$DIR/deployment.env"; images_of "$DIR/previous.env"; } | while read -r ref; do
    docker image inspect --format '{{.Id}}' "$ref" 2>/dev/null || true
  done)
  for repo in $(images_of "$DIR/deployment.env" | sed 's/@.*//'); do
    for id in $(docker image ls --no-trunc --quiet "$repo"); do
      grep -qxF "$id" <<<"$keep" || docker image rm "$id" >/dev/null 2>&1 || true
    done
  done
}

run_release() { fetch_kit "$DIR/deployment.env" >> "$LOG" 2>&1 && DEPLOY_DIR=$DIR demiurge-admin release >> "$LOG" 2>&1; }

move() { moving "$@"; rm -f "$DIR/moving"; }
moving() {   # onto the env file given: the one Terraform set
  local next="$1" name before_convex
  name=$(release_of "$next")
  status releasing "$next" "$name"
  cp "$DIR/deployment.env" "$DIR/previous.env"
  touch "$DIR/moving"   # a boot mid-move starts previous.env again (startup.sh), and this move is tried afresh
  before_convex=$(convex_image)
  install -m 600 "$next" "$DIR/deployment.env"
  if run_release; then
    cp "$DIR/deployment.env" "$DIR/released.env"
    status released "$next" "$name"
    tidy || true
    return
  fi
  cp "$next" "$DIR/failed.env"
  if [ "$(convex_image)" != "$before_convex" ]; then
    status failed "$next" "$name: Convex's image moved, so it isn't rolled back; restore from the export taken before (docs/deploy.md §8)"
    return
  fi
  install -m 600 "$DIR/previous.env" "$DIR/deployment.env"
  if run_release; then
    cp "$DIR/deployment.env" "$DIR/released.env"
    status rolled-back "$next" "$name: back on $(release_of "$DIR/deployment.env"); $LOG on the VM says why"
  else
    status failed "$next" "$name: and going back failed too; $LOG on the VM says why"
  fi
}

follow() {
  local etag="" body headers raw next mine wait=3600
  headers=$(mktemp) body=$(mktemp) raw=$(mktemp) next=$(mktemp) mine=$(mktemp)
  while true; do
    # Returns at once the first time, then whenever any of the instance's metadata changes, or after `wait` seconds
    # (five minutes when following a channel, so a promotion is seen soon).
    if ! curl -fsS -H "Metadata-Flavor: Google" -D "$headers" -o "$body" \
        "$METADATA/attributes/?recursive=true&wait_for_change=true&timeout_sec=$wait&last_etag=${etag:-0}"; then
      sleep 10; continue
    fi
    # The snapshot that came back with the change, not a second read that could fail after its ETag is spent.
    python3 -c 'import json, sys
attributes = json.load(open(sys.argv[1]))
open(sys.argv[2], "w").write(attributes.get("deployment-env", ""))
open(sys.argv[3], "w").write(attributes.get("demiurge-follow", ""))' "$body" "$raw" "$mine" || { sleep 10; continue; }
    etag=$(sed -n 's/^[Ee][Tt]ag: *\([^[:space:]]*\).*/\1/p' "$headers")
    # A different follower replaces this one, and systemd restarts it: the release's own (in its kit) when there is one,
    # so a fix to it arrives with a release; otherwise the module's, from the metadata.
    [ -f /opt/demiurge/infra/gcp/follow.sh ] && cp /opt/demiurge/infra/gcp/follow.sh "$mine"
    if [ -s "$mine" ] && ! cmp -s "$mine" "$SELF"; then
      install -m 755 "$mine" "$SELF"
      exit 0
    fi
    [ -s "$raw" ] || continue
    if grep -q '^ *CHANNEL="[^"]' "$raw"; then wait=300; else wait=3600; fi
    if ! resolve "$raw" "$next"; then
      status failed "$raw" "couldn't name its release's images by digest, or they changed; $LOG on the VM says why"
      continue
    fi
    exec 8>"$LOCK"
    flock 8
    if [ ! -f "$DIR/.initialized" ]; then   # nothing runs before init, which starts what the settings name with this kit
      if ! cmp -s "$next" "$DIR/released.env"; then
        install -m 600 "$next" "$DIR/deployment.env"
        if fetch_kit "$DIR/deployment.env" >> "$LOG" 2>&1; then
          cp "$next" "$DIR/released.env"
        else
          install -m 600 "$DIR/released.env" "$DIR/deployment.env" 2>/dev/null || true
        fi
      fi
      if cmp -s "$next" "$DIR/released.env"; then
        status not-set-up "$next" "run demiurge-admin init"
      else
        status failed "$next" "$(release_of "$next"): couldn't fetch its images; $LOG on the VM says why"
      fi
    elif cmp -s "$next" "$DIR/released.env"; then
      status released "$next" "$(release_of "$next")"
    elif cmp -s "$next" "$DIR/failed.env"; then   # already tried and went back: wait for the next change
      status failed "$next" "$(release_of "$next"): tried already and went back; change the settings to try again"
    else
      move "$next"
    fi
    flock -u 8
  done
}

if [ "${1:-}" = follow ]; then follow; fi
