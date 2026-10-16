#!/usr/bin/env bash
# Prove the latest DB dump restores. Usage: restore-test.sh <site> [--offsite]
# Restores the newest dump into a scratch database <db>_restoretest using a dedicated MySQL
# user that only has rights on that database, compares table count, published-post count and
# siteurl with production, then drops the scratch database (always, via a trap).
# With --offsite the dump is fetched from the off-site remote instead of the local disk.
#
# Memory protection (the import can raise MySQL server memory; this runs from cron with no one
# watching). "Headroom" is MemAvailable + SwapFree from ${MEMINFO_FILE:-/proc/meminfo}.
#   RESTORE_MIN_MEM_MB=1536       refuse to start below this headroom (0 = no pre-check)
#   RESTORE_ABORT_MEM_MB=512      kill the import if headroom falls below this (0 = no watchdog)
#   RESTORE_MEM_POLL_SECONDS=2    how often the import is checked
# The abort floor must be below the start threshold when both are set.
#
# The production database is protected twice: the scratch name and the MySQL user are different
# (the user has no grants on production), and the guards below refuse to run otherwise.
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/backup/lib.sh
source "$SCRIPT_DIR/lib.sh"

SITE="${1:-}"
MODE="${2:-local}"
if [[ -z "$SITE" || ( "$MODE" != "local" && "$MODE" != "--offsite" ) ]]; then
  echo "usage: ${0##*/} <site> [--offsite]" >&2
  exit 64
fi

STARTED=0
IMPORT_PID=""
SCRATCH_ARMED=0
SCRATCH_DB=""
WORKDIR=""
LAST_CMD=""
trap 'LAST_CMD=$BASH_COMMAND' ERR

rt_mysql() { mysql --defaults-extra-file="$RESTORE_DEFAULTS_FILE" "$@"; }

drop_scratch() {
  [[ $SCRATCH_ARMED -eq 1 ]] || return 0
  rt_mysql -e "DROP DATABASE IF EXISTS \`$SCRATCH_DB\`" || log "WARNING: could not drop $SCRATCH_DB"
}

on_exit() {
  local rc=$?
  trap - EXIT ERR
  if [[ -n "$IMPORT_PID" ]]; then
    kill_tree "$IMPORT_PID" KILL
    wait "$IMPORT_PID" 2>/dev/null || true
  fi
  drop_scratch
  [[ -z "$WORKDIR" ]] || rm -rf -- "$WORKDIR"
  if [[ $rc -ne 0 && $STARTED -eq 1 ]]; then
    [[ -n "$FAIL_MSG" ]] || FAIL_MSG="command failed (exit $rc): $LAST_CMD"
    log "RESTORE TEST FAILED: $FAIL_MSG"
    send_alert_mail "[devnel-backup] RESTORE TEST FAILED: $SITE" "$FAIL_MSG (host $(hostname), see $LOG_FILE)"
    ping_hc "$RESTORE_HEARTBEAT_URL" /fail "$FAIL_MSG"
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 143' TERM INT HUP

load_config "$SITE"
STARTED=1
: "${RESTORE_DEFAULTS_FILE:?RESTORE_DEFAULTS_FILE is not set in the site config}"
: "${RESTORE_POSTS_TOLERANCE:=0}"
is_uint "$RESTORE_POSTS_TOLERANCE" || die "RESTORE_POSTS_TOLERANCE must be a non-negative integer"
: "${RESTORE_MIN_MEM_MB:=1536}"
: "${RESTORE_ABORT_MEM_MB:=512}"
: "${RESTORE_MEM_POLL_SECONDS:=2}"
is_uint "$RESTORE_MIN_MEM_MB" || die "RESTORE_MIN_MEM_MB must be a non-negative integer"
is_uint "$RESTORE_ABORT_MEM_MB" || die "RESTORE_ABORT_MEM_MB must be a non-negative integer"
if ! is_uint "$RESTORE_MEM_POLL_SECONDS" || [[ "$RESTORE_MEM_POLL_SECONDS" -lt 1 ]]; then
  die "RESTORE_MEM_POLL_SECONDS must be a positive integer"
fi
if [[ "$RESTORE_MIN_MEM_MB" -ne 0 && "$RESTORE_ABORT_MEM_MB" -ne 0 && "$RESTORE_ABORT_MEM_MB" -ge "$RESTORE_MIN_MEM_MB" ]]; then
  die "RESTORE_ABORT_MEM_MB ($RESTORE_ABORT_MEM_MB) must be less than RESTORE_MIN_MEM_MB ($RESTORE_MIN_MEM_MB)"
fi
require_private_file "$RESTORE_DEFAULTS_FILE" "restore defaults file"

wp_site() { "$WP_BIN" --path="$SITE_ROOT" "$@"; }

PROD_DB="${DB_NAME:-$(wp_site config get DB_NAME)}"
PROD_USER="$(wp_site config get DB_USER)"
[[ "$PROD_DB" =~ ^[A-Za-z0-9_]+$ ]] || die "unexpected production database name '$PROD_DB'"
SCRATCH_DB="${RESTORE_DB:-${PROD_DB}_restoretest}"

# --- Guards: nothing below runs unless these pass. ---
[[ "$SCRATCH_DB" =~ ^[A-Za-z0-9_]+$ ]] || die "unexpected scratch database name '$SCRATCH_DB'"
[[ "$SCRATCH_DB" != "$PROD_DB" ]] || die "refusing: scratch database equals the production database ($PROD_DB)"
[[ "$SCRATCH_DB" == *_restoretest ]] || die "refusing: scratch database name must end in _restoretest (got $SCRATCH_DB)"
[[ "$SCRATCH_DB" != "_restoretest" ]] || die "refusing: scratch database name has no base name"
[[ "$RESTORE_DEFAULTS_FILE" != "$DB_DEFAULTS_FILE" ]] || die "refusing: restore and backup use the same MySQL credentials file"
RESTORE_USER="$(rt_mysql -N -B -e 'SELECT SUBSTRING_INDEX(CURRENT_USER(), "@", 1)')"
[[ -n "$RESTORE_USER" && "$RESTORE_USER" != "$PROD_USER" ]] ||
  die "refusing: the restore MySQL user must differ from the production user ($PROD_USER)"
# USE succeeds only if the user holds some privilege on the database, so this proves it can't touch production.
if rt_mysql -e "USE \`$PROD_DB\`" >/dev/null 2>&1; then
  die "refusing: the restore MySQL user has access to the production database $PROD_DB"
fi

PREFIX="$(wp_site db prefix)"
[[ "$PREFIX" =~ ^[A-Za-z0-9_]+$ ]] || die "unexpected table prefix '$PREFIX'"

log "restore test start ($MODE)"
ping_hc "$RESTORE_HEARTBEAT_URL" /start

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/devnel-restoretest.XXXXXX")"

# --- Pick the dump. ---
if [[ "$MODE" == "--offsite" ]]; then
  [[ -n "$OFFSITE_REMOTE" ]] || die "OFFSITE_REMOTE is not set"
  latest="$(rclone lsf --files-only "${OFFSITE_REMOTE%/}/db" | sort | tail -n 1)"
  [[ "$latest" == *_database.sql.gz ]] || die "no database dump found off-site (got '$latest')"
  DUMP="$WORKDIR/$latest"
  rclone copyto "${OFFSITE_REMOTE%/}/db/$latest" "$DUMP" || die "could not fetch $latest from off-site"
else
  shopt -s nullglob
  dumps=("$BACKUP_DIR"/*_database.sql.gz)
  shopt -u nullglob
  [[ ${#dumps[@]} -gt 0 ]] || die "no local database dump in $BACKUP_DIR"
  DUMP="${dumps[${#dumps[@]} - 1]}"
fi
log "testing $(basename "$DUMP")"

# --- Validate the dump before loading it. ---
gzip -t "$DUMP" || die "dump is not a valid gzip file"
first="$(gzip -dc "$DUMP" | sed -n '1p')"
[[ "$first" == "-- MySQL dump"* ]] || die "dump does not start with '-- MySQL dump' (got: ${first:0:60})"
# Count matches rather than using grep -q: -q exits early, gzip gets SIGPIPE, and pipefail would
# make the test fail open on large dumps.
db_stmts="$(gzip -dc "$DUMP" | grep -Eic '^(USE |CREATE DATABASE)' || true)"
if [[ "$db_stmts" -gt 0 ]]; then
  die "refusing: the dump selects or creates a database; it would not stay in the scratch database"
fi

# --- Disk guard: the scratch DB lives on the same filesystem as production MySQL. ---
: "${RESTORE_MIN_FREE_FACTOR:=3}"
if ! is_uint "$RESTORE_MIN_FREE_FACTOR" || [[ "$RESTORE_MIN_FREE_FACTOR" -lt 1 ]]; then
  die "RESTORE_MIN_FREE_FACTOR must be a positive integer"
fi
# Stream-count the uncompressed size: `gzip -l` wraps around for files over 4 GB.
dump_bytes="$(gzip -dc "$DUMP" | wc -c | tr -d ' ')"
dump_kb=$(((dump_bytes + 1023) / 1024))
datadir="${MYSQL_DATADIR:-$(rt_mysql -N -B -e 'SELECT @@datadir')}"
[[ -n "$datadir" ]] || die "could not determine the MySQL data directory (set MYSQL_DATADIR)"
check_free_space "$datadir" "$dump_kb" "$RESTORE_MIN_FREE_FACTOR" "restore test"

# --- Memory guard: the import raises MySQL server memory, which production shares. ---
START_MEM=""
if [[ "$RESTORE_MIN_MEM_MB" -ne 0 ]]; then
  START_MEM="$(mem_headroom_mb)" ||
    die "cannot read MemAvailable and SwapFree from ${MEMINFO_FILE:-/proc/meminfo}; refusing to run the restore test without a memory check"
  log "memory headroom at start: ${START_MEM} MB (RAM + swap), ${RESTORE_MIN_MEM_MB} MB required"
  [[ "$START_MEM" -ge "$RESTORE_MIN_MEM_MB" ]] ||
    die "not enough free memory for restore test: ${START_MEM} MB available (RAM + swap), ${RESTORE_MIN_MEM_MB} MB required"
else
  log "memory pre-check disabled (RESTORE_MIN_MEM_MB=0)"
fi
LOWEST_MEM="$START_MEM"

# import_with_watchdog: run the import in the background and poll memory headroom from this
# shell while it runs, so there is no separate watchdog process that could outlive the script.
# The import and everything it spawned are killed if headroom drops below RESTORE_ABORT_MEM_MB.
import_with_watchdog() {
  local rc=0 tick=0 ticks_per_poll=$((RESTORE_MEM_POLL_SECONDS * 10)) now
  (gzip -dc "$DUMP" | rt_mysql --default-character-set=utf8mb4 "$SCRATCH_DB") &
  IMPORT_PID=$!
  if [[ "$RESTORE_ABORT_MEM_MB" -ne 0 ]]; then
    while kill -0 "$IMPORT_PID" 2>/dev/null; do
      if [[ $((tick % ticks_per_poll)) -eq 0 ]]; then
        if ! now="$(mem_headroom_mb)"; then
          FAIL_MSG="import aborted: cannot read MemAvailable and SwapFree from ${MEMINFO_FILE:-/proc/meminfo}"
        else
          if [[ -z "$LOWEST_MEM" || "$now" -lt "$LOWEST_MEM" ]]; then LOWEST_MEM="$now"; fi
          if [[ "$now" -lt "$RESTORE_ABORT_MEM_MB" ]]; then
            FAIL_MSG="import aborted: memory headroom fell to ${now} MB (floor ${RESTORE_ABORT_MEM_MB} MB)"
          fi
        fi
        if [[ -n "$FAIL_MSG" ]]; then
          log "ERROR: $FAIL_MSG; killing the import"
          kill_tree "$IMPORT_PID" TERM
          for _ in $(seq 1 50); do kill -0 "$IMPORT_PID" 2>/dev/null || break; sleep 0.1; done
          kill_tree "$IMPORT_PID" KILL
          wait "$IMPORT_PID" 2>/dev/null || true
          IMPORT_PID=""
          exit 1
        fi
      fi
      tick=$((tick + 1))
      sleep 0.1
    done
  fi
  wait "$IMPORT_PID" || rc=$?
  IMPORT_PID=""
  return "$rc"
}

# --- Restore into the scratch database. ---
SCRATCH_ARMED=1
rt_mysql -e "DROP DATABASE IF EXISTS \`$SCRATCH_DB\`; CREATE DATABASE \`$SCRATCH_DB\` CHARACTER SET utf8mb4"
import_with_watchdog

# --- Compare with production (read-only queries through wp db query). ---
scratch_q() { rt_mysql -N -B "$SCRATCH_DB" -e "$1"; }
prod_q() { wp_site db query "$1" --skip-column-names; }

PUBLISHED_SQL="SELECT COUNT(*) FROM \`${PREFIX}posts\` WHERE post_status = 'publish'"
SITEURL_SQL="SELECT option_value FROM \`${PREFIX}options\` WHERE option_name = 'siteurl'"

s_tables="$(scratch_q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$SCRATCH_DB'")"
p_tables="$(prod_q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()")"
s_pub="$(scratch_q "$PUBLISHED_SQL")"
p_pub="$(prod_q "$PUBLISHED_SQL")"
s_url="$(scratch_q "$SITEURL_SQL")"
p_url="$(prod_q "$SITEURL_SQL")"

log "tables: restored=$s_tables production=$p_tables"
log "published posts/pages: restored=$s_pub production=$p_pub (tolerance $RESTORE_POSTS_TOLERANCE)"
log "siteurl: restored=$s_url production=$p_url"

for v in "$s_tables" "$p_tables" "$s_pub" "$p_pub"; do
  is_uint "$v" || die "could not read counts (got '$v')"
done
problems=()
[[ "$s_tables" -eq "$p_tables" ]] || problems+=("table count differs ($s_tables restored vs $p_tables production)")
diff=$((s_pub > p_pub ? s_pub - p_pub : p_pub - s_pub))
[[ "$diff" -le "$RESTORE_POSTS_TOLERANCE" ]] || problems+=("published count differs ($s_pub vs $p_pub)")
[[ "$s_url" == "$p_url" ]] || problems+=("siteurl differs ($s_url vs $p_url)")
if [[ ${#problems[@]} -gt 0 ]]; then
  die "restore test mismatch for $(basename "$DUMP"): ${problems[*]}"
fi

drop_scratch
SCRATCH_ARMED=0
if [[ "$RESTORE_ABORT_MEM_MB" -ne 0 && -n "$LOWEST_MEM" ]]; then
  log "memory headroom: ${START_MEM:-n/a} MB at start, lowest ${LOWEST_MEM} MB during import (abort floor ${RESTORE_ABORT_MEM_MB} MB)"
else
  log "memory headroom: ${START_MEM:-not measured} MB at start, import not monitored"
fi
log "restore test passed ($(basename "$DUMP"), $s_tables tables, $s_pub published)"
ping_hc "$RESTORE_HEARTBEAT_URL"
