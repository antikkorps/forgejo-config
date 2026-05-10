#!/usr/bin/env bash
# Restore from R2 backup. Usage: ./restore.sh [snapshot-id|latest]
# DESTRUCTIVE — wipes current ./data/forgejo and the postgres database.

set -euo pipefail

cd "$(dirname "$0")/.."

set -a
# shellcheck disable=SC1091
source .env
set +a

SNAPSHOT="${1:-latest}"
RESTORE_DIR="$(mktemp -d)"
trap 'rm -rf "$RESTORE_DIR"' EXIT

read -r -p "This will overwrite Forgejo data and database. Continue? (yes/no) " confirm
[ "$confirm" = "yes" ] || { echo "aborted"; exit 1; }

echo "==> restic restore $SNAPSHOT"
restic restore "$SNAPSHOT" --target "$RESTORE_DIR"

echo "==> stopping forgejo"
docker compose stop forgejo

echo "==> restoring file data"
rm -rf ./data/forgejo ./data/forgejo-config
cp -a "$RESTORE_DIR"/*/data/forgejo ./data/forgejo
cp -a "$RESTORE_DIR"/*/data/forgejo-config ./data/forgejo-config

echo "==> restoring postgres dump"
DUMP_PATH=$(find "$RESTORE_DIR" -name 'forgejo.dump' | head -n1)
[ -n "$DUMP_PATH" ] || { echo "no dump found in snapshot"; exit 1; }

docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" forgejo-postgres \
	dropdb -U "$POSTGRES_USER" --if-exists "$POSTGRES_DB"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" forgejo-postgres \
	createdb -U "$POSTGRES_USER" "$POSTGRES_DB"
docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" forgejo-postgres \
	pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner < "$DUMP_PATH"

echo "==> starting forgejo"
docker compose start forgejo

echo "==> done. Verify at https://${FORGEJO_DOMAIN}"
