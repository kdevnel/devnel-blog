#!/usr/bin/env bash
# Shared helpers for backup.sh and restore-test.sh. Source this file; don't run it.
# shellcheck shell=bash

# cron has a minimal PATH; wp lives in /usr/local/bin on Triton. Append, so
# anything earlier on PATH (tests put stubs first) still wins.
export PATH="$PATH:/usr/local/bin:/usr/bin:/bin"

CONFIG_DIR="${DEVNEL_BACKUP_CONFIG_DIR:-$HOME/.config/devnel-backup}"
# Set by the site config (default <parent of SITE_ROOT>/logs/backup.log, applied in load_config).
LOG_FILE=""
# shellcheck disable=SC2034 # read by the scripts that source this file
FAIL_MSG=""

log() {
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) [$$] ${SITE:-?}: $*"
  if [[ -n "$LOG_FILE" ]]; then printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true; fi
  printf '%s\n' "$line" >&2
}

die() {
  # shellcheck disable=SC2034 # read by the sourcing script's exit trap
  FAIL_MSG="$*"
  log "ERROR: $*"
  exit 1
}

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# Octal permission bits of a file (GNU stat, then BSD stat).
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# Refuse a secrets file that anyone but the owner can read or write.
require_private_file() {
  local f="$1" what="$2" mode
  [[ -f "$f" ]] || die "$what not found: $f"
  mode="$(file_mode "$f")"
  [[ "$mode" == "600" || "$mode" == "400" ]] || die "$what must be mode 600 (is $mode): $f"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Site names are used in paths, so keep them boring.
validate_site_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid site name: $1"
}

# Source ~/.config/devnel-backup/<site>.env (shell syntax, mode 600, ours).
load_config() {
  local site="$1" cfg v
  validate_site_name "$site"
  cfg="$CONFIG_DIR/$site.env"
  require_private_file "$cfg" "config file"
  LOG_FILE=""
  # shellcheck disable=SC1090
  source "$cfg"
  : "${SITE_ROOT:?SITE_ROOT is not set in $cfg}"
  : "${BACKUP_DIR:?BACKUP_DIR is not set in $cfg}"
  : "${DB_DEFAULTS_FILE:?DB_DEFAULTS_FILE is not set in $cfg}"
  : "${LOG_FILE:=$(dirname "$SITE_ROOT")/logs/backup.log}"
  : "${WP_BIN:=wp}"
  : "${MIN_FREE_FACTOR:=2}"
  : "${DB_FALLBACK_EXPECTED_MB:=200}"
  : "${LOCAL_RETENTION_DB_DAYS:=14}"
  : "${LOCAL_RETENTION_FILES_DAYS:=56}"
  : "${OFFSITE_RETENTION_DB_DAYS:=90}"
  : "${OFFSITE_RETENTION_FILES_DAYS:=182}"
  : "${HEARTBEAT_URL_DB:=}"
  : "${HEARTBEAT_URL_FILES:=}"
  : "${RESTORE_HEARTBEAT_URL:=}"
  : "${ALERT_EMAIL:=}"
  : "${OFFSITE_REMOTE:=}"
  : "${NGINX_CONF:=}"
  for v in MIN_FREE_FACTOR DB_FALLBACK_EXPECTED_MB LOCAL_RETENTION_DB_DAYS LOCAL_RETENTION_FILES_DAYS \
    OFFSITE_RETENTION_DB_DAYS OFFSITE_RETENTION_FILES_DAYS; do
    if ! is_uint "${!v}" || [[ "${!v}" -lt 1 ]]; then die "$v must be a positive integer (is '${!v}')"; fi
  done
  mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR" # new directories are 700 (umask 077 in the scripts)
  chmod 700 "$BACKUP_DIR"
}

# Paths under SITE_ROOT that are left out of the files backup (rebuildable, or old UpdraftPlus
# backups). Shared by the tar command and the disk-space estimate so the two can't drift apart.
# shellcheck disable=SC2034 # used by backup.sh
WP_CONTENT_EXCLUDES=(wp-content/cache wp-content/upgrade wp-content/updraft)

# free_kb <path>: free space in KB on the filesystem holding <path>.
free_kb() { df -Pk "$1" | awk 'NR==2 {print $4}'; }

# check_free_space <path> <expected KB> <factor> <what>: die unless <path>'s filesystem has
# at least <factor> times <expected KB> free.
check_free_space() {
  local path="$1" expected_kb="$2" factor="$3" what="$4" avail_kb need_kb
  avail_kb="$(free_kb "$path")"
  is_uint "$avail_kb" || die "could not read free disk space for $path"
  need_kb=$((expected_kb * factor))
  log "disk ($what): ${avail_kb} KB free, ${need_kb} KB required (${factor}x expected ${expected_kb} KB)"
  [[ $avail_kb -ge $need_kb ]] || die "not enough free disk for $what: ${avail_kb} KB free, need ${need_kb} KB"
}

# mem_headroom_mb: print MemAvailable + SwapFree in whole MB from ${MEMINFO_FILE:-/proc/meminfo}.
# Returns 1 (printing nothing) if the file is unreadable or either field is missing or not a number.
mem_headroom_mb() {
  local f="${MEMINFO_FILE:-/proc/meminfo}"
  [[ -r "$f" ]] || return 1
  awk '
    $1 == "MemAvailable:" { a = $2; ha = 1 }
    $1 == "SwapFree:" { s = $2; hs = 1 }
    END {
      if (ha && hs && a ~ /^[0-9]+$/ && s ~ /^[0-9]+$/) { printf "%d\n", (a + s) / 1024 } else { exit 1 }
    }' "$f" 2>/dev/null
}

# kill_tree <pid> [signal]: signal a process and all its descendants (children first). Never fails.
kill_tree() {
  local pid="$1" sig="${2:-TERM}" child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do kill_tree "$child" "$sig"; done
  kill "-$sig" "$pid" 2>/dev/null || true
}

# Healthchecks API: <url>/start, <url>, <url>/fail. A failed ping never fails the job.
ping_hc() {
  local url="$1" suffix="${2:-}" body="${3:-}"
  [[ -n "$url" ]] || return 0
  curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "$body" "${url%/}${suffix}" ||
    log "WARNING: heartbeat ping${suffix:+ $suffix} failed"
}

# Email through WordPress (Post SMTP). Subject and body go through the environment, never quoted into PHP.
send_alert_mail() {
  local subject="$1" body="$2"
  DEVNEL_ALERT_TO="$ALERT_EMAIL" DEVNEL_ALERT_SUBJECT="$subject" DEVNEL_ALERT_BODY="$body" \
    "$WP_BIN" --path="$SITE_ROOT" eval \
    'wp_mail( getenv( "DEVNEL_ALERT_TO" ) ? getenv( "DEVNEL_ALERT_TO" ) : get_option( "admin_email" ), getenv( "DEVNEL_ALERT_SUBJECT" ), getenv( "DEVNEL_ALERT_BODY" ) );' \
    >/dev/null 2>&1 || log "WARNING: could not send alert email"
}
