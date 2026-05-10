#!/usr/bin/env bash
# Daily encrypted backup of Forgejo + Postgres to Cloudflare R2 via restic.
# Pings healthchecks.io on success/failure so silent failures get noticed.

set -euo pipefail

cd "$(dirname "$0")/.."

# Load env (RESTIC_*, AWS_*, POSTGRES_*, HEALTHCHECK_URL)
set -a
# shellcheck disable=SC1091
source .env
set +a

DUMP_DIR="$(mktemp -d)"
trap 'rm -rf "$DUMP_DIR"' EXIT

ping_hc() {
	local endpoint="${1:-}"
	[ -n "${HEALTHCHECK_URL:-}" ] && curl -fsS --retry 3 -m 10 \
		"${HEALTHCHECK_URL}${endpoint}" >/dev/null || true
}

fail() {
	echo "BACKUP FAILED: $*" >&2
	ping_hc "/fail"
	exit 1
}

ping_hc "/start"

# 1. Postgres dump
echo "==> pg_dump"
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" forgejo-postgres \
	pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom \
	> "$DUMP_DIR/forgejo.dump" || fail "pg_dump"

# 2. Init repo if first run (idempotent)
restic snapshots >/dev/null 2>&1 || restic init || fail "restic init"

# 3. Backup dump + forgejo data + config
echo "==> restic backup"
restic backup \
	--tag forgejo \
	--host "$(hostname)" \
	"$DUMP_DIR/forgejo.dump" \
	./data/forgejo \
	|| fail "restic backup"

# 4. Retention — note: NO --prune. R2 Object Lock (30d) prevents
#    rewriting/deleting locked pack files. We only mark snapshots as
#    forgotten here; actual pack pruning is done manually from a trusted
#    machine with the admin R2 token, after objects exit the lock window.
echo "==> restic forget (mark only, no prune)"
restic forget \
	--keep-daily 7 \
	--keep-weekly 4 \
	--keep-monthly 6 \
	|| fail "restic forget"

ping_hc ""
echo "==> done"
