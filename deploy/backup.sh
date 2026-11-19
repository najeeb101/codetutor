#!/usr/bin/env bash
# A dump of the real database (Deploy Step 5, docs/deploy.md §10). cron runs it every night
# (deploy/setup-server.sh); by hand, from the repo:
#     deploy/backup.sh
# Keeps the newest KEEP dumps in BACKUP_DIR. The simulated class is not backed up: make
# prod-demo-data rebuilds it. The dumps are on the server's own disk, so they undo a bad
# delete or migration, not the loss of the VM: copy one off the server now and then.
set -euo pipefail
cd "$(dirname "$0")/.."

BACKUP_DIR="${BACKUP_DIR:-/var/backups/codetutor}"
KEEP="${KEEP:-7}"
COMPOSE=(docker compose -f compose.prod.yaml --env-file .env.prod)
# compose.prod.yaml requires DOCKER_GID even for exec (make sets it the same way).
DOCKER_GID="$(stat -c %g /var/run/docker.sock)"
export DOCKER_GID

mkdir -p "$BACKUP_DIR"
out="$BACKUP_DIR/codetutor-$(date -u +%Y-%m-%dT%H%M%SZ).dump"
trap 'rm -f "$out.part"' EXIT

"${COMPOSE[@]}" exec -T db pg_dump -U codetutor -d codetutor --format=custom > "$out.part"
# A dump that can't be listed is not a backup: fail loudly instead of keeping it.
"${COMPOSE[@]}" exec -T db pg_restore --list < "$out.part" > /dev/null
chmod 0600 "$out.part"
mv "$out.part" "$out"
echo "$(date -u +%FT%TZ) wrote $out ($(du -h "$out" | cut -f1))"

find "$BACKUP_DIR" -maxdepth 1 -name 'codetutor-*.dump' -printf '%f\n' | sort -r \
    | tail -n +"$((KEEP + 1))" | while read -r old; do
        rm -f -- "$BACKUP_DIR/$old"
        echo "removed $old"
    done
