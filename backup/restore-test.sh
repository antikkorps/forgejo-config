#!/usr/bin/env bash
# Non-destructive restore test. Pulls the latest snapshot from R2, restores
# the pg dump into a throwaway Postgres container, sanity-checks the Forgejo
# data dir, and pings healthchecks.io. Run monthly via cron.

set -euo pipefail

cd "$(dirname "$0")/.."

set -a
# shellcheck disable=SC1091
source .env
set +a

WORK_DIR="$(mktemp -d)"
PG_CONTAINER="forgejo-restore-test-$$"
HC_URL="${RESTORE_TEST_HEALTHCHECK_URL:-${HEALTHCHECK_URL:-}}"

cleanup() {
	docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
	rm -rf "$WORK_DIR"
}
trap cleanup EXIT

ping_hc() {
	local endpoint="${1:-}"
	[ -n "$HC_URL" ] && curl -fsS --retry 3 -m 10 "${HC_URL}${endpoint}" >/dev/null || true
}

fail() {
	echo "RESTORE-TEST FAILED: $*" >&2
	ping_hc "/fail"
	exit 1
}

ping_hc "/start"

echo "==> restic restore latest"
restic restore latest --target "$WORK_DIR" || fail "restic restore"

DUMP_PATH=$(find "$WORK_DIR" -name 'forgejo.dump' | head -n1)
[ -n "$DUMP_PATH" ] || fail "no forgejo.dump in snapshot"

DATA_DIR=$(find "$WORK_DIR" -type d -name forgejo -path '*/data/*' | head -n1)
[ -n "$DATA_DIR" ] || fail "no data/forgejo dir in snapshot"
[ -d "$DATA_DIR/git" ] || fail "data/forgejo/git missing — snapshot looks incomplete"

echo "==> spinning throwaway postgres"
docker run -d --name "$PG_CONTAINER" \
	-e POSTGRES_PASSWORD=test \
	-e POSTGRES_USER=test \
	-e POSTGRES_DB=forgejo_restore_test \
	postgres:16-alpine >/dev/null || fail "start pg"

# Wait for it
for _ in $(seq 1 30); do
	docker exec "$PG_CONTAINER" pg_isready -U test >/dev/null 2>&1 && break
	sleep 1
done
docker exec "$PG_CONTAINER" pg_isready -U test >/dev/null 2>&1 \
	|| fail "throwaway pg never became ready"

echo "==> pg_restore (smoke test)"
docker exec -i -e PGPASSWORD=test "$PG_CONTAINER" \
	pg_restore -U test -d forgejo_restore_test --no-owner < "$DUMP_PATH" \
	2> "$WORK_DIR/restore.err" \
	|| { cat "$WORK_DIR/restore.err" >&2; fail "pg_restore"; }

# Sanity: at least the user table should exist and be non-empty
USER_COUNT=$(docker exec -e PGPASSWORD=test "$PG_CONTAINER" \
	psql -U test -d forgejo_restore_test -tAc 'SELECT count(*) FROM "user";' 2>/dev/null \
	|| echo "0")
[ "$USER_COUNT" -gt 0 ] || fail "user table empty or missing in restored db"

echo "==> OK — snapshot restorable, $USER_COUNT users, data dir intact"
ping_hc ""
