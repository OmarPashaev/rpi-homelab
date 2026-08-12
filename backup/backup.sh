#!/usr/bin/env bash
set -euo pipefail

export RESTIC_REPOSITORY="/mnt/backup/restic"
export RESTIC_PASSWORD_FILE="/root/.restic-password"

DOCKER_DIR="/home/rpi5/docker"
STAGING="${DOCKER_DIR}/_backup-staging"
HOST_SNAP="${STAGING}/host-state"
NC_COMPOSE="${DOCKER_DIR}/nextcloud/docker-compose.yml"

WEEKLY=0
[ "$(date +%u)" -eq 7 ] && WEEKLY=1

NC_MAINTENANCE=0
cleanup() {
    if [ "${NC_MAINTENANCE}" -eq 1 ]; then
        docker compose -f "${NC_COMPOSE}" exec -T -u www-data app \
            php occ maintenance:mode --off || true
    fi
}
trap cleanup EXIT

backup_sqlite() {
    local owner
    owner="$(stat -c '%u:%g' "$1")"
    sqlite3 "$1" ".backup '$2'"
    chown "${owner}" "$1"-wal "$1"-shm 2>/dev/null || true
    if [ "$(sqlite3 "$2" 'PRAGMA integrity_check;')" != "ok" ]; then
        echo "ERROR: integrity check failed for $2" >&2
        exit 1
    fi
}

if ! mountpoint -q /mnt/backup; then
    echo "ERROR: /mnt/backup not mounted. Is the WD Elements connected?" >&2
    exit 1
fi

echo "==> Releasing stale repository locks..."
restic unlock

rm -rf "${STAGING}"
mkdir -p "${HOST_SNAP}"
chmod 700 "${STAGING}"

echo "==> Snapshotting host state..."
tar -cf "${HOST_SNAP}/etc-subset.tar" --ignore-failed-read \
    /etc/crypttab \
    /etc/fstab \
    /etc/hosts \
    /etc/cloud/cloud.cfg \
    /etc/initramfs-tools \
    /etc/dropbear/initramfs \
    /etc/ssh/sshd_config.d \
    /etc/systemd/system \
    /boot/firmware/cmdline.txt \
    /boot/firmware/config.txt 2>/dev/null || true

cp -a /home/rpi5/.ssh  "${HOST_SNAP}/dot-ssh"
cp -a /home/rpi5/x120x "${HOST_SNAP}/x120x"

command -v rpi-eeprom-config >/dev/null && \
    rpi-eeprom-config > "${HOST_SNAP}/eeprom-config.txt"

dpkg --get-selections > "${HOST_SNAP}/dpkg-selections.txt"

echo "==> Dumping Authelia..."
backup_sqlite "${DOCKER_DIR}/authelia/config/db.sqlite3" \
              "${STAGING}/authelia-db.sqlite3"

echo "==> Dumping Grafana..."
backup_sqlite "${DOCKER_DIR}/monitoring/grafana/data/grafana.db" \
              "${STAGING}/grafana.db"

echo "==> Dumping Uptime Kuma..."
backup_sqlite "${DOCKER_DIR}/uptime-kuma/data/kuma.db" \
              "${STAGING}/kuma.db"

echo "==> Dumping Forgejo..."
docker exec -u git forgejo forgejo dump --type tar --file /tmp/forgejo-dump.tar
docker cp forgejo:/tmp/forgejo-dump.tar "${STAGING}/forgejo-dump.tar"
docker exec forgejo rm -f /tmp/forgejo-dump.tar

echo "==> Securing mkcert CA root..."
cp -a /home/rpi5/.local/share/mkcert/. "${STAGING}/mkcert-CAROOT/"

echo "==> Entering Nextcloud maintenance mode..."
docker compose -f "${NC_COMPOSE}" exec -T -u www-data app \
    php occ maintenance:mode --on
NC_MAINTENANCE=1

echo "==> Dumping Nextcloud database..."
docker compose -f "${NC_COMPOSE}" exec -T db \
    pg_dump -U nextcloud nextcloud > "${STAGING}/nextcloud.sql"

echo "==> Running restic backup..."
restic backup "${DOCKER_DIR}" \
    --tag automated \
    --exclude "${DOCKER_DIR}/**/data/repo-archive" \
    --exclude "${DOCKER_DIR}/monitoring/prometheus/data" \
    --exclude "${DOCKER_DIR}/logging/loki/data" \
    --verbose

echo "==> Leaving Nextcloud maintenance mode..."
docker compose -f "${NC_COMPOSE}" exec -T -u www-data app \
    php occ maintenance:mode --off
NC_MAINTENANCE=0

echo "==> Forgetting old snapshots..."
restic forget \
    --tag automated \
    --keep-last 3 \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6

if [ "${WEEKLY}" -eq 1 ]; then
    echo "==> Weekly: pruning..."
    restic prune
    echo "==> Weekly: structural check..."
    restic check
fi

echo "==> Copying snapshots off-site to Backblaze B2..."
if [ -r /root/.restic-b2.env ]; then
    . /root/.restic-b2.env

    restic -r "${B2_REPO}" --password-file "${B2_PASSWORD_FILE}" unlock

    restic -r "${B2_REPO}" --password-file "${B2_PASSWORD_FILE}" \
        copy --from-repo "${RESTIC_REPOSITORY}" \
             --from-password-file "${RESTIC_PASSWORD_FILE}" \
             --limit-upload 5000
else
    echo "WARNING: /root/.restic-b2.env not readable, skipping off-site copy" >&2
fi

echo "==> Backup finished: $(date)"
