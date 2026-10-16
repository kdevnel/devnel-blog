#!/usr/bin/env bash
# Pull a sanitised copy of the production database into wp-env.
#
# Raw production data never touches disk and never enters wp-env:
#   1. the export streams over ssh (read-only: `wp db export -` writes to stdout) straight into a
#      throwaway MySQL container with no network and no published ports;
#   2. it is sanitised there with plain SQL, and scripts/check-sanitised.sh must pass against it;
#   3. only then is the sanitised database written to .data/sanitised-YYYYMMDD.sql.gz and imported
#      into wp-env, where URLs are rewritten and the check runs again.
# The container is removed on every exit path. If anything fails before step 3, wp-env is untouched.
#
# Usage: scripts/pull-db.sh
# Environment (mostly for tests): DEVNEL_PROD_HOST, DEVNEL_DATA_DIR, DEVNEL_MYSQL_IMAGE, WP_ENV.
set -euo pipefail
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/sanitise/lib.sh
source "$root/scripts/sanitise/lib.sh"

PROD_HOST="${DEVNEL_PROD_HOST:-triton.devnel.com}"
# The only command run on production. Read-only: the export goes to stdout.
PROD_EXPORT_CMD='cd ~/devnel.blog/public && wp db export - --single-transaction'
PROD_URL="https://devnel.blog"
LOCAL_URL="http://localhost:8888"
IMAGE="${DEVNEL_MYSQL_IMAGE:-mysql:8.4}"
DATA_DIR="${DEVNEL_DATA_DIR:-$root/.data}"
CHECK_SCRIPT="${DEVNEL_CHECK_SCRIPT:-$root/scripts/check-sanitised.sh}"
KEEP_SNAPSHOTS=3
READY_TRIES="${DEVNEL_READY_TRIES:-60}"
READY_SLEEP="${DEVNEL_READY_SLEEP:-2}"
WP_ENV="${WP_ENV:-npx wp-env}"
export WP_ENV

log() { printf '[pull-db] %s\n' "$*" >&2; }
die() {
  printf '[pull-db] ERROR: %s\n' "$*" >&2
  exit 1
}

# wpenv <wp args...>: run WP-CLI in the wp-env development site.
wpenv() {
  # shellcheck disable=SC2086 # WP_ENV is a command prefix such as "npx wp-env"
  $WP_ENV run cli wp "$@"
}

container=""
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n "$container" ]]; then
    docker rm -f -v "$container" >/dev/null 2>&1 || log "WARNING: could not remove container $container; remove it by hand"
    container=""
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Preflight: nothing here touches production or wp-env's database ---------------------------
command -v docker >/dev/null 2>&1 || die "docker not found"
command -v ssh >/dev/null 2>&1 || die "ssh not found"
docker info >/dev/null 2>&1 || die "docker is not running"

mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"
data_real="$(cd -P "$DATA_DIR" && pwd)"
# Snapshots must never be committable: if the data directory is inside the repository, git has to
# ignore it. (A directory outside the repository is fine.)
root_real="$(cd -P "$root" && pwd)"
if [[ "$data_real" == "$root_real" || "$data_real" == "$root_real"/* ]]; then
  git -C "$root" check-ignore -q -- "$data_real/sanitised-probe.sql.gz" ||
    die "$data_real is not gitignored; refusing to write snapshots there"
fi

wpenv core version >/dev/null 2>&1 || die "wp-env is not running (npm run env:start)"

# --- 1. Throwaway, isolated MySQL container ----------------------------------------------------
suffix="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
name="devnel-sanitise-$suffix"
log "starting isolated container $name ($IMAGE, no network, no published ports, data in memory)"
# --network none: nothing can reach it and it can reach nothing; the only way in is docker exec.
# The root account has no password because the server is not reachable over any network.
docker run -d --name "$name" --network none \
  --tmpfs /var/lib/mysql:rw,mode=1777 \
  -e MYSQL_ALLOW_EMPTY_PASSWORD=1 -e MYSQL_DATABASE="$SAN_DB" \
  "$IMAGE" --skip-log-bin --max-allowed-packet=256M --innodb-flush-log-at-trx-commit=2 \
  >/dev/null || die "could not start the container"
container="$name"

# Wait for the real server. mysqld first runs a temporary server (no TCP) to initialise the
# database, so ping over TCP: it only answers once the final server is up.
ready=""
for ((i = 1; i <= READY_TRIES; i++)); do
  if docker exec "$container" mysqladmin ping -h 127.0.0.1 --protocol=tcp -uroot --silent >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep "$READY_SLEEP"
done
[[ -n "$ready" ]] || die "the MySQL container did not become ready"

# --- 2. Stream production straight into the container ------------------------------------------
log "streaming the production export into the container (read-only on production)"
# shellcheck disable=SC2029 # the command is a constant, expanded on the client on purpose
ssh "$PROD_HOST" "$PROD_EXPORT_CMD" |
  docker exec -i "$container" mysql -uroot --default-character-set=utf8mb4 "$SAN_DB" ||
  die "the export or the import into the container failed; nothing was imported into wp-env"

posts="$(echo "SELECT COUNT(*) FROM ${SAN_PREFIX}posts;" | san_run "container:$container")" ||
  die "the streamed database has no ${SAN_PREFIX}posts table"
[[ "${posts:-0}" -gt 0 ]] || die "the streamed database is empty"

# --- 3. Sanitise and verify, still in the container --------------------------------------------
log "sanitising"
san_sanitise "container:$container" || die "sanitising failed"
log "checking the container"
"$CHECK_SCRIPT" --container "$container" || die "the sanitised database failed the check; nothing was imported"

# --- 4. Export the sanitised database ----------------------------------------------------------
snapshot="$DATA_DIR/sanitised-$(date +%Y%m%d).sql.gz"
tmp_snapshot="$snapshot.tmp.$$"
log "writing ${snapshot#"$root_real"/}"
if ! docker exec "$container" mysqldump -uroot --single-transaction --default-character-set=utf8mb4 "$SAN_DB" |
  gzip -c >"$tmp_snapshot"; then
  rm -f "$tmp_snapshot"
  die "exporting the sanitised database failed"
fi
chmod 600 "$tmp_snapshot"
mv -f "$tmp_snapshot" "$snapshot"

# Keep the newest snapshots only (names sort by date).
old="$(find "$DATA_DIR" -maxdepth 1 -type f -name 'sanitised-*.sql.gz' | sort -r | tail -n +$((KEEP_SNAPSHOTS + 1)))"
if [[ -n "$old" ]]; then
  while IFS= read -r f; do rm -f -- "$f"; done <<<"$old"
fi

# The raw data has done its job.
docker rm -f -v "$container" >/dev/null 2>&1 && container=""

# --- 5. Import into wp-env ---------------------------------------------------------------------
log "importing into wp-env"
gzip -dc "$snapshot" | wpenv db import - || die "importing into wp-env failed (wp-env may be partially imported; re-run)"

# URLs only. --precise handles serialised data.
wpenv search-replace "$PROD_URL" "$LOCAL_URL" --all-tables --precise >/dev/null
wpenv rewrite flush >/dev/null

# A known local admin (every real password hash was replaced).
if wpenv user get admin >/dev/null 2>&1; then
  wpenv user update admin --user_pass=password --role=administrator >/dev/null
else
  wpenv user create admin admin@example.test --role=administrator --user_pass=password >/dev/null
fi

# Plugins that talk to the outside world or manage production.
while IFS= read -r plugin; do
  wpenv plugin deactivate "$plugin" >/dev/null 2>&1 || log "note: $plugin not active or not installed locally"
done < <(san_entries "$SAN_DIR/deactivate-plugins.txt")

# WordPress writes fresh transients (and plugins may regenerate their own keys) while the commands
# above run. They hold nothing from production, but the check rightly refuses them, so remove them
# again: the same DELETE the sanitiser ran.
san_delete_options wpenv || die "could not clear locally generated options"

log "checking wp-env"
"$CHECK_SCRIPT" --wp-env || die "wp-env failed the sanitisation check"

# --- Summary -----------------------------------------------------------------------------------
count() { wpenv "$@" --format=count 2>/dev/null | tr -d '[:space:]'; }
echo "Imported a sanitised copy of production into wp-env ($LOCAL_URL)."
echo "  published posts: $(count post list --post_type=post --post_status=publish)"
echo "  published pages: $(count post list --post_type=page --post_status=publish)"
echo "  comments:        $(count comment list)"
echo "  users:           $(count user list)"
echo "  snapshot:        ${snapshot#"$root_real"/}"
echo "Log in at $LOCAL_URL/wp-admin with admin / password (local only)."
