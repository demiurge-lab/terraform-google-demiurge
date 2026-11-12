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

# The settings with the release they mean: a channel (CHANNEL) is looked up in Demiurge's bucket and its release and
# images added, so everything after sees a pinned release. Fails when the lookup does.
resolve() {
  local from="$1" to="$2" channel channels registry version
  channel=$(sed -n 's/^ *CHANNEL="\(.*\)"$/\1/p' "$from")
  install -m 600 "$from" "$to"
  [ -n "$channel" ] || return 0
  channels=$(sed -n 's/^ *CHANNELS="\(.*\)"$/\1/p' "$from")
  registry=$(sed -n 's/^ *IMAGE_REGISTRY="\(.*\)"$/\1/p' "$from")
  version=$(gcloud storage cat "$channels/$channel" 2>>"$LOG" | tr -d '[:space:]') || return 1
  [[ "$version" =~ ^v[0-9][0-9.]*$ ]] || { echo "$(date -Is) channel $channel names \"$version\", not a release" >> "$LOG"; return 1; }
  printf 'RELEASE="%s"\nHARNESS_IMAGE="%s/demiurge-harness:%s"\nWEB_IMAGE="%s/demiurge-web:%s"\n' \
    "$version" "$registry" "$version" "$registry" "$version" >> "$to"
}
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
      status failed "$raw" "couldn't look up the channel's release; $LOG on the VM says why"
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
