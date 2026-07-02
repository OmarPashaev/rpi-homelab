#!/usr/bin/env bash
set -euo pipefail

export RESTIC_REPOSITORY="/mnt/backup/restic"
export RESTIC_PASSWORD_FILE="/root/.restic-password"

DOCKER_DIR="/home/rpi5/docker"
STAGING="${DOCKER_DIR}/_backup-staging"

if ! mountpoint -q /mnt/backup; then
    echo "ERROR: /mnt/backup not mounted. Is the WD Elements connected?" >&2
    exit 1
fi

rm -rf "${STAGING}"
mkdir -p "${STAGING}"

echo "==> Dumping Authelia..."
sqlite3 "${DOCKER_DIR}/authelia/config/db.sqlite3" ".backup '${STAGING}/authelia-db.sqlite3'"

echo "==> Dumping Forgejo..."
docker exec -u git forgejo forgejo dump --type tar --file /tmp/forgejo-dump.tar
docker cp forgejo:/tmp/forgejo-dump.tar "${STAGING}/forgejo-dump.tar"
docker exec forgejo rm -f /tmp/forgejo-dump.tar

echo "==> Securing mkcert CA root..."
cp -a /home/rpi5/.local/share/mkcert/. "${STAGING}/mkcert-CAROOT/"

echo "==> Dumping Nextcloud..."
docker compose -f /home/rpi5/docker/nextcloud/docker-compose.yml exec -T -u www-data app php occ maintenance:mode --on
docker compose -f /home/rpi5/docker/nextcloud/docker-compose.yml exec -T db pg_dump -U nextcloud nextcloud > "${STAGING}/nextcloud.sql"
docker compose -f /home/rpi5/docker/nextcloud/docker-compose.yml exec -T -u www-data app php occ maintenance:mode --off

echo "==> Running restic backup..."
restic backup "${DOCKER_DIR}" \
    --tag automated \
    --exclude "${DOCKER_DIR}/**/data/repo-archive" \
    --verbose

echo "==> Pruning old snapshots..."
restic forget \
    --tag automated \
    --keep-last 3 \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --prune

echo "==> Backup finished: $(date)"
