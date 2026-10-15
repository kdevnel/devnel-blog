# Shared setup for backup.bats and restore-test.bats. Builds a throwaway site, config and
# backup directory under $BATS_TEST_TMPDIR and puts the stubs in tests/shell/stubs first on PATH.
# The variables below and write_config's arguments are used from the .bats files, which the
# linter can't see from here, so SC2034, SC2119 and SC2120 are false positives.
# shellcheck disable=SC2034,SC2119,SC2120

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
BACKUP_SH="$REPO_ROOT/scripts/backup/backup.sh"
RESTORE_SH="$REPO_ROOT/scripts/backup/restore-test.sh"

backup_setup() {
  REAL_GZIP="$(command -v gzip)"
  export REAL_GZIP
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  : >"$STUB_LOG"
  export PATH="$REPO_ROOT/tests/shell/stubs:$PATH"

  SITE_ROOT="$BATS_TEST_TMPDIR/site/public"
  BACKUP_DIR="$BATS_TEST_TMPDIR/site/backups"
  mkdir -p "$SITE_ROOT/wp-content/uploads" "$SITE_ROOT/wp-content/cache" "$BATS_TEST_TMPDIR/cfg"
  echo "hello" >"$SITE_ROOT/wp-content/uploads/a.txt"
  echo "junk" >"$SITE_ROOT/wp-content/cache/c.txt"
  echo "server {}" >"$BATS_TEST_TMPDIR/nginx-site.conf"

  export DEVNEL_BACKUP_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  printf '[client]\nuser=prod\npassword="s3cret-prod-pw"\n' >"$BATS_TEST_TMPDIR/prod.my.cnf"
  printf '[client]\nuser=restore\npassword="s3cret-restore-pw"\n' >"$BATS_TEST_TMPDIR/restore.my.cnf"
  chmod 600 "$BATS_TEST_TMPDIR/prod.my.cnf" "$BATS_TEST_TMPDIR/restore.my.cnf"
  write_config
}

write_config() { # extra lines may be passed as arguments
  {
    echo "SITE_ROOT='$SITE_ROOT'"
    echo "BACKUP_DIR='$BACKUP_DIR'"
    if [[ -z "${NO_LOG_FILE:-}" ]]; then echo "LOG_FILE='$BATS_TEST_TMPDIR/site/backup.log'"; fi
    echo "DB_DEFAULTS_FILE='$BATS_TEST_TMPDIR/prod.my.cnf'"
    echo "RESTORE_DEFAULTS_FILE='$BATS_TEST_TMPDIR/restore.my.cnf'"
    echo "NGINX_CONF='$BATS_TEST_TMPDIR/nginx-site.conf'"
    echo "OFFSITE_REMOTE='devnel-crypt:devnel.blog'"
    echo "HEARTBEAT_URL_DB='https://hc.example.test/ping/db-uuid'"
    echo "HEARTBEAT_URL_FILES='https://hc.example.test/ping/files-uuid'"
    echo "RESTORE_HEARTBEAT_URL='https://hc.example.test/ping/restore-uuid'"
    printf '%s\n' "$@"
  } >"$DEVNEL_BACKUP_CONFIG_DIR/test.env"
  chmod 600 "$DEVNEL_BACKUP_CONFIG_DIR/test.env"
}

# touch_days_old <days> <file>: set a file's mtime that many days in the past (BSD and GNU date).
touch_days_old() {
  local stamp
  stamp="$(date -v-"$1"d +%Y%m%d%H%M 2>/dev/null || date -d "$1 days ago" +%Y%m%d%H%M)"
  touch -t "$stamp" "$2"
}

# Files in BACKUP_DIR that are not the marker or a lock.
backup_files_list() { find "$BACKUP_DIR" -maxdepth 1 -type f ! -name 'last-success' ! -name '.lock-*' | sort; }

# mode_of <path>: octal permission bits (GNU then BSD stat).
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
