#!/bin/bash
# The VM's start (docs/deploy.md §3), run by GCE at every boot: Docker, the data disk, the deployment's settings, the
# kit from the release's harness image, and, once `demiurge-admin init` has run, everything started.
set -euo pipefail

if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -q && apt-get install -yq docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

# The data disk: formatted only the first time, mounted at /srv/demiurge.
disk=/dev/disk/by-id/google-demiurge-data
mkdir -p /srv/demiurge
blkid "$disk" >/dev/null || mkfs.ext4 -q -F "$disk"
grep -q " /srv/demiurge " /etc/fstab || echo "$disk /srv/demiurge ext4 defaults,nofail 0 2" >> /etc/fstab
mountpoint -q /srv/demiurge || mount /srv/demiurge
mkdir -p /srv/demiurge/data
chown 1000:1000 /srv/demiurge/data   # the harness image's user writes the vaults and workspaces

metadata() { curl -fsS -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"; }
# What keeps the VM on the release Terraform sets (follow.sh): this waits out any move it's making, then stops it while
# setting things up, and starts it again at the end.
exec 9>/run/demiurge-release.lock
flock 9
systemctl stop demiurge-follow.service 2>/dev/null || true
metadata demiurge-follow > /usr/local/lib/demiurge-follow.sh
chmod 755 /usr/local/lib/demiurge-follow.sh
# shellcheck source=follow.sh
. /usr/local/lib/demiurge-follow.sh

# A boot starts what was running (deployment.env, kept on the data disk), and the follower then moves onto whatever
# Terraform has set since, through the whole release: a recreated VM is upgraded the same careful way. Before init
# nothing runs, so the settings Terraform set are simply taken.
target=$(mktemp) resolved=$(mktemp)
metadata deployment-env > "$target"
if [ ! -f /srv/demiurge/.initialized ] || [ ! -f /srv/demiurge/deployment.env ]; then
  # A channel is looked up in Demiurge's bucket, which a new deployment waits to be granted, as with its images.
  until resolve "$target" "$resolved"; do
    echo "waiting to read the channel's release: Demiurge grants $(metadata ../service-accounts/default/email 2>/dev/null || echo "this VM's service account") access"
    sleep 30
  done
  install -m 600 "$resolved" /srv/demiurge/deployment.env
elif [ -f /srv/demiurge/moving ] && [ -f /srv/demiurge/previous.env ]; then
  # Stopped mid-move: start what ran before; the follower tries the move again from the top, export first.
  install -m 600 /srv/demiurge/previous.env /srv/demiurge/deployment.env
  rm -f /srv/demiurge/moving
fi

# The release's images, and the kit (demiurge-admin, the Compose file) from inside the harness image. On a new
# deployment this waits until Demiurge has granted the VM's service account read access to its registry.
until fetch_kit /srv/demiurge/deployment.env; do
  echo "waiting to read the release's images: Demiurge grants $(metadata ../service-accounts/default/email 2>/dev/null || echo "this VM's service account") access to its registry"
  sleep 30
done

cat > /etc/systemd/system/demiurge-export.service <<UNIT
[Unit]
Description=Convex's nightly export to the bucket
[Service]
Type=oneshot
Environment=DEPLOY_DIR=/srv/demiurge
ExecStart=/usr/local/bin/demiurge-admin export
UNIT
cat > /etc/systemd/system/demiurge-export.timer <<UNIT
[Unit]
Description=Convex's nightly export
[Timer]
OnCalendar=*-*-* 09:30:00
Persistent=true
[Install]
WantedBy=timers.target
UNIT
cat > /etc/systemd/system/demiurge-follow.service <<UNIT
[Unit]
Description=Moves the VM onto the release and settings Terraform last set
After=docker.service
[Service]
ExecStart=/usr/local/lib/demiurge-follow.sh follow
Restart=always
RestartSec=30
UNIT
systemctl daemon-reload
systemctl enable --now demiurge-export.timer

# Started only once set up: `demiurge-admin init` makes the keys the services need.
if [ -f /srv/demiurge/.initialized ]; then
  DEPLOY_DIR=/srv/demiurge demiurge-admin up
else
  cp /srv/demiurge/deployment.env /srv/demiurge/released.env
fi
flock -u 9
systemctl start demiurge-follow.service
