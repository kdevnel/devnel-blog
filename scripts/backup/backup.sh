#!/usr/bin/env bash
# Back up one site. Usage: backup.sh <site> <db|files>
#   db     gzip'd mysqldump (daily)
#   files  wp-content tarball + nginx site config (weekly)
# Config: ~/.config/devnel-backup/<site>.env (see deploy/backup/devnel.blog.env.example).
# Every artefact is written to a temp file in BACKUP_DIR, verified, then moved into place
# with an atomic mv, so a failure never replaces or leaves behind a half-written backup.
set -Eeuo pipefail
umask 077 # dumps, archives, logs and the marker are private to the owner

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/backup/lib.sh
source "$SCRIPT_DIR/lib.sh"

SITE="${1:-}"
KIND="${2:-}"
if [[ -z "$SITE" || ( "$KIND" != "db" && "$KIND" != "files" ) ]]; then
  echo "usage: ${0##*/} <site> <db|files>" >&2
  exit 64
fi

STARTED=0
TMP_FILES=()
HB_URL=""
LAST_CMD=""
trap 'LAST_CMD=$BASH_COMMAND' ERR

on_exit() {
  local rc=$?
  trap - EXIT ERR
  local f
  for f in "${TMP_FILES[@]+"${TMP_FILES[@]}"}"; do rm -f -- "$f"; done
  if [[ $rc -ne 0 && $STARTED -eq 1 ]]; then
    [[ -n "$FAIL_MSG" ]] || FAIL_MSG="command failed (exit $rc): $LAST_CMD"
    log "FAILED ($KIND): $FAIL_MSG"
    send_alert_mail "[devnel-backup] FAILED: $SITE $KIND" "$FAIL_MSG (host $(hostname), see $LOG_FILE)"
    ping_hc "$HB_URL" /fail "$FAIL_MSG"
  fi
  exit "$rc"
}
trap on_exit EXIT

load_config "$SITE"
case "$KIND" in
  db) HB_URL="$HEARTBEAT_URL_DB" ;;
  files) HB_URL="$HEARTBEAT_URL_FILES" ;;
esac
STARTED=1 # from here on a failure sends the alert email and the /fail ping
require_private_file "$DB_DEFAULTS_FILE" "DB defaults file"
[[ -d "$SITE_ROOT/wp-content" ]] || die "SITE_ROOT has no wp-content: $SITE_ROOT"

# One run per site at a time (flock is absent on macOS; production has it).
if command -v flock >/dev/null 2>&1; then
  exec 9>"$BACKUP_DIR/.lock-$SITE"
  # Wait (up to 30 min) so a long DB run delays the files run instead of failing it.
  flock -w 1800 9 || die "another backup for $SITE was still running after 30 minutes"
fi

log "start $KIND"
ping_hc "$HB_URL" /start
[[ -n "$HB_URL" ]] || log "WARNING: no heartbeat URL configured for $KIND"

# Leftovers from a run that was killed outright (SIGKILL, power loss).
find "$BACKUP_DIR" -maxdepth 1 -type f -name '.tmp.*' -mtime +1 -delete

TS="$(date +%Y%m%d%H%M%S)"

# newest_match <name-suffix>: file names start with a sortable timestamp.
newest_match() {
  local -a m
  shopt -s nullglob
  m=("$BACKUP_DIR"/*"$1")
  shopt -u nullglob
  if [[ ${#m[@]} -gt 0 ]]; then printf '%s\n' "${m[${#m[@]} - 1]}"; fi
}

# check_disk <expected backup size in KB>
check_disk() { check_free_space "$BACKUP_DIR" "$1" "$MIN_FREE_FACTOR" "backup"; }

# files_expected_kb: size of wp-content without the paths tar excludes (same list, see lib.sh).
files_expected_kb() {
  local kb e ex
  kb="$(du -sk "$SITE_ROOT/wp-content" | cut -f1)"
  for e in "${WP_CONTENT_EXCLUDES[@]}"; do
    if [[ -d "$SITE_ROOT/$e" ]]; then
      ex="$(du -sk "$SITE_ROOT/$e" | cut -f1)"
      kb=$((kb - ex))
    fi
  done
  printf '%s\n' "$kb"
}

# new_tmp <suffix>: sets NEW_TMP to a temp path in BACKUP_DIR (same filesystem, so mv is atomic), removed on exit.
# Not run in a subshell, or the cleanup list would be lost.
NEW_TMP=""
new_tmp() {
  NEW_TMP="$BACKUP_DIR/.tmp.$$.$1"
  TMP_FILES+=("$NEW_TMP")
}

# publish <tmp> <final>: atomic move into place.
publish() { mv -f -- "$1" "$2"; }

# offsite_copy <file> <subdir>
offsite_copy() {
  if [[ -z "$OFFSITE_REMOTE" ]]; then
    log "WARNING: OFFSITE_REMOTE not set; skipping off-site copy"
    return 0
  fi
  log "off-site: copying $(basename "$1")"
  rclone copyto "$1" "${OFFSITE_REMOTE%/}/$2/$(basename "$1")" || die "off-site copy failed for $(basename "$1")"
}

# offsite_prune <subdir> <days>: Drive has no lifecycle rules, so prune here and skip the Drive trash.
offsite_prune() {
  [[ -n "$OFFSITE_REMOTE" ]] || return 0
  log "off-site: pruning $1 older than $2 days"
  local rc=0
  rclone delete --min-age "${2}d" --drive-use-trash=false "${OFFSITE_REMOTE%/}/$1" || rc=$?
  # rclone exit 3 = directory not found: nothing has been uploaded there, so nothing to prune.
  if [[ $rc -eq 3 ]]; then
    log "off-site: $1 does not exist yet; nothing to prune"
  elif [[ $rc -ne 0 ]]; then
    die "off-site prune failed for $1 (rclone exit $rc)"
  fi
}

# local_prune <name-glob> <days>
local_prune() {
  log "local: pruning $1 older than $2 days"
  find "$BACKUP_DIR" -maxdepth 1 -type f -name "$1" -mtime "+$2" -delete
}

# write_marker <file> <sha256>: replaces only this kind's keys, atomically.
write_marker() {
  local marker="$BACKUP_DIR/last-success" tmp
  new_tmp marker
  tmp="$NEW_TMP"
  {
    if [[ -f "$marker" ]]; then grep -v "^${KIND}_" "$marker" || true; fi
    printf '%s_time=%s\n%s_file=%s\n%s_sha256=%s\n' \
      "$KIND" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$KIND" "$(basename "$1")" "$KIND" "$2"
  } >"$tmp"
  chmod 600 "$tmp"
  publish "$tmp" "$marker"
}

backup_db() {
  local db prev expected_kb tmp final first last
  db="${DB_NAME:-$("$WP_BIN" --path="$SITE_ROOT" config get DB_NAME)}"
  [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || die "unexpected database name '$db'"

  prev="$(newest_match _database.sql.gz)"
  if [[ -n "$prev" ]]; then
    expected_kb="$(du -k "$prev" | cut -f1)"
  else
    expected_kb=$((DB_FALLBACK_EXPECTED_MB * 1024))
  fi
  check_disk "$expected_kb"

  new_tmp database.sql.gz
  tmp="$NEW_TMP"
  final="$BACKUP_DIR/${TS}_database.sql.gz"
  log "dumping $db"
  # stderr goes to the log, never into the dump; pipefail makes a mysqldump failure fatal.
  mysqldump --defaults-extra-file="$DB_DEFAULTS_FILE" --single-transaction --quick --routines --triggers \
    --no-tablespaces --default-character-set=utf8mb4 "$db" 2>>"$LOG_FILE" | gzip -c >"$tmp"

  gzip -t "$tmp" || die "dump is not a valid gzip file"
  first="$(gzip -dc "$tmp" | sed -n '1p')"
  [[ "$first" == "-- MySQL dump"* ]] || die "dump does not start with '-- MySQL dump' (got: ${first:0:60})"
  last="$(gzip -dc "$tmp" | tail -n 1)"
  [[ "$last" == "-- Dump completed"* ]] || die "dump is incomplete (no '-- Dump completed' trailer)"
  publish "$tmp" "$final"
  log "wrote $(basename "$final")"

  offsite_copy "$final" db
  write_marker "$final" "$(sha256_of "$final")"
  local_prune '*_database.sql.gz' "$LOCAL_RETENTION_DB_DAYS"
  offsite_prune db "$OFFSITE_RETENTION_DB_DAYS"
}

backup_files() {
  local tmp final rc=0 nginx_tmp nginx_final=""
  check_disk "$(files_expected_kb)"

  new_tmp files.tar.gz
  tmp="$NEW_TMP"
  final="$BACKUP_DIR/${TS}_files.tar.gz"
  log "archiving wp-content"
  local -a excludes=()
  local e
  for e in "${WP_CONTENT_EXCLUDES[@]}"; do excludes+=("--exclude=$e"); done
  tar -czf "$tmp" -C "$SITE_ROOT" "${excludes[@]}" \
    wp-content 2>>"$LOG_FILE" || rc=$?
  # tar exits 1 when a file changed while it was read (a live site); anything higher is a real failure.
  [[ $rc -le 1 ]] || die "tar failed (exit $rc)"
  [[ $rc -eq 0 ]] || log "WARNING: tar reported files changing during the read"
  gzip -t "$tmp" || die "files archive is not a valid gzip file"
  tar -tzf "$tmp" >/dev/null || die "files archive cannot be listed"
  publish "$tmp" "$final"
  log "wrote $(basename "$final")"

  if [[ -n "$NGINX_CONF" ]]; then
    [[ -r "$NGINX_CONF" ]] || die "NGINX_CONF is not readable: $NGINX_CONF"
    new_tmp nginx.conf
    nginx_tmp="$NEW_TMP"
    nginx_final="$BACKUP_DIR/${TS}_nginx.conf"
    cp -- "$NGINX_CONF" "$nginx_tmp"
    publish "$nginx_tmp" "$nginx_final"
  fi

  offsite_copy "$final" files
  if [[ -n "$nginx_final" ]]; then offsite_copy "$nginx_final" nginx; fi
  write_marker "$final" "$(sha256_of "$final")"
  local_prune '*_files.tar.gz' "$LOCAL_RETENTION_FILES_DAYS"
  local_prune '*_nginx.conf' "$LOCAL_RETENTION_FILES_DAYS"
  offsite_prune files "$OFFSITE_RETENTION_FILES_DAYS"
  if [[ -n "$NGINX_CONF" ]]; then offsite_prune nginx "$OFFSITE_RETENTION_FILES_DAYS"; fi
}

"backup_$KIND"
log "success ($KIND)"
ping_hc "$HB_URL"
