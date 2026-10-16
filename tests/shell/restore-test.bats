#!/usr/bin/env bats
# Tests for scripts/backup/restore-test.sh with stubbed mysql, wp, rclone, curl.

load backup_helper

setup() {
  backup_setup
  mkdir -p "$BACKUP_DIR"
  make_dump "$BACKUP_DIR/20260101000000_database.sql.gz"
}

make_dump() { printf -- '-- MySQL dump 10.13\nCREATE TABLE t (id int);\n-- Dump completed on x\n' | gzip >"$1"; }

run_rt() { run "$RESTORE_SH" test "$@"; }

scratch_dropped() { grep -q 'DROP DATABASE IF EXISTS `devnel_blog_restoretest`' "$STUB_LOG"; }

@test "matching counts pass, scratch DB is created then dropped, heartbeat pings" {
  run_rt
  [ "$status" -eq 0 ]
  grep -q 'CREATE DATABASE `devnel_blog_restoretest`' "$STUB_LOG"
  grep -q 'mysql IMPORT .* devnel_blog_restoretest' "$STUB_LOG"
  [ "$(grep -c 'DROP DATABASE IF EXISTS `devnel_blog_restoretest`' "$STUB_LOG")" -ge 2 ]
  grep -q 'curl https://hc.example.test/ping/restore-uuid/start' "$STUB_LOG"
  grep -q 'curl https://hc.example.test/ping/restore-uuid$' "$STUB_LOG"
  ! grep -q 'DROP DATABASE.*`devnel_blog`' "$STUB_LOG"
}

@test "table count mismatch fails, alerts, and still drops the scratch DB" {
  STUB_SCRATCH_TABLES=11 run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"table count differs"* ]]
  scratch_dropped
  [ "$(grep -c 'DROP DATABASE' "$STUB_LOG")" -ge 2 ]
  grep -q 'ALERT subject=\[devnel-backup\] RESTORE TEST FAILED' "$STUB_LOG"
  grep -q 'restore-uuid/fail' "$STUB_LOG"
}

@test "published count mismatch fails; tolerance allows a small drift" {
  STUB_SCRATCH_PUBLISHED=8 run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"published count differs"* ]]
  write_config "RESTORE_POSTS_TOLERANCE=1"
  STUB_SCRATCH_PUBLISHED=8 run_rt
  [ "$status" -eq 0 ]
}

@test "siteurl mismatch fails" {
  STUB_SCRATCH_SITEURL=https://staging.example run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"siteurl differs"* ]]
}

@test "import failure still drops the scratch DB" {
  STUB_MYSQL_IMPORT_RC=1 run_rt
  [ "$status" -ne 0 ]
  [ "$(grep -c 'DROP DATABASE IF EXISTS `devnel_blog_restoretest`' "$STUB_LOG")" -ge 2 ]
}

@test "failure creating the scratch DB still runs the drop" {
  STUB_MYSQL_FAIL_CREATE=1 run_rt
  [ "$status" -ne 0 ]
  [ "$(grep -c 'DROP DATABASE IF EXISTS `devnel_blog_restoretest`' "$STUB_LOG")" -ge 2 ]
}

@test "guard: scratch DB equal to the production DB is refused before any SQL on it" {
  write_config "RESTORE_DB=devnel_blog"
  run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"equals the production database"* ]]
  ! grep -q 'CREATE DATABASE\|DROP DATABASE\|mysql IMPORT' "$STUB_LOG"
}

@test "guard: scratch DB without the _restoretest suffix is refused" {
  write_config "RESTORE_DB=devnel_blog_scratch"
  run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"must end in _restoretest"* ]]
  ! grep -q 'CREATE DATABASE\|DROP DATABASE\|mysql IMPORT' "$STUB_LOG"
}

@test "guard: restore user equal to the production DB user is refused" {
  STUB_MYSQL_USER=devnel_prod run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"must differ from the production user"* ]]
  ! grep -q 'CREATE DATABASE\|DROP DATABASE\|mysql IMPORT' "$STUB_LOG"
}

@test "guard: restore user with access to the production DB is refused" {
  STUB_MYSQL_PROD_ACCESS=1 run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"has access to the production database"* ]]
  ! grep -q 'CREATE DATABASE\|DROP DATABASE\|mysql IMPORT' "$STUB_LOG"
}

@test "guard: same credentials file for backup and restore is refused" {
  write_config "RESTORE_DEFAULTS_FILE='$BATS_TEST_TMPDIR/prod.my.cnf'"
  run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"same MySQL credentials file"* ]]
  ! grep -q 'CREATE DATABASE\|DROP DATABASE' "$STUB_LOG"
}

@test "restore defaults file must be mode 600" {
  chmod 644 "$BATS_TEST_TMPDIR/restore.my.cnf"
  run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be mode 600"* ]]
}

@test "bad dump header is refused without touching MySQL" {
  printf 'mysqldump: [Warning] Using a password\n-- MySQL dump\n' | gzip >"$BACKUP_DIR/20260102000000_database.sql.gz"
  run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not start with"* ]]
  ! grep -q 'CREATE DATABASE' "$STUB_LOG"
}

@test "a dump that selects a database is refused" {
  printf -- '-- MySQL dump\nUSE `devnel_blog`;\n-- Dump completed\n' | gzip >"$BACKUP_DIR/20260102000000_database.sql.gz"
  run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"selects or creates a database"* ]]
  ! grep -q 'CREATE DATABASE' "$STUB_LOG"
}

@test "a large dump that selects a database is still refused (grep -q + pipefail must not fail open)" {
  {
    echo '-- MySQL dump 10.13'
    echo 'USE `devnel_blog`;'
    yes 'INSERT INTO t VALUES (1,2,3,4,5,6,7,8,9,10);' | head -n 400000
    echo '-- Dump completed on x'
  } | gzip >"$BACKUP_DIR/20260102000000_database.sql.gz"
  run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"selects or creates a database"* ]]
  ! grep -q 'CREATE DATABASE' "$STUB_LOG"
}

@test "the newest local dump is the one tested" {
  make_dump "$BACKUP_DIR/20260301000000_database.sql.gz"
  run_rt
  [ "$status" -eq 0 ]
  [[ "$output" == *"testing 20260301000000_database.sql.gz"* ]]
}

@test "--offsite fetches the newest off-site dump and restores it" {
  make_dump "$BATS_TEST_TMPDIR/fetched.gz"
  export STUB_RCLONE_FETCH_FILE="$BATS_TEST_TMPDIR/fetched.gz"
  export STUB_RCLONE_LSF=$'20260101000000_database.sql.gz\n20260401000000_database.sql.gz'
  run_rt --offsite
  [ "$status" -eq 0 ]
  grep -q 'rclone copyto devnel-crypt:devnel.blog/db/20260401000000_database.sql.gz' "$STUB_LOG"
  [[ "$output" == *"testing 20260401000000_database.sql.gz"* ]]
}

@test "no dump available fails with an alert" {
  rm "$BACKUP_DIR"/*_database.sql.gz
  run_rt
  [ "$status" -ne 0 ]
  grep -q 'RESTORE TEST FAILED' "$STUB_LOG"
}

big_dump() { # big_dump <file>: about 2 MB uncompressed
  { echo '-- MySQL dump 10.13'; yes 'INSERT INTO t VALUES (1,2,3,4,5,6,7,8,9,10);' | head -n 42000; echo '-- Dump completed on x'; } | gzip >"$1"
}

@test "disk guard: low free space in the MySQL datadir aborts before CREATE DATABASE, with an alert" {
  big_dump "$BACKUP_DIR/20260102000000_database.sql.gz"   # ~2000 KB x 3 = ~6000 KB needed
  STUB_DF_AVAIL_KB=5000 run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"not enough free disk for restore test"* ]]
  ! grep -q 'CREATE DATABASE\|mysql IMPORT' "$STUB_LOG"
  grep -q 'ALERT subject=\[devnel-backup\] RESTORE TEST FAILED' "$STUB_LOG"
  grep -q 'restore-uuid/fail' "$STUB_LOG"
  grep -q '^df -Pk /var/lib/mysql/' "$STUB_LOG"
}

@test "disk guard: enough free space passes, and the factor is configurable" {
  big_dump "$BACKUP_DIR/20260102000000_database.sql.gz"
  STUB_DF_AVAIL_KB=6500 run_rt
  [ "$status" -eq 0 ]
  write_config "RESTORE_MIN_FREE_FACTOR=10"
  STUB_DF_AVAIL_KB=6500 run_rt
  [ "$status" -ne 0 ]
}

@test "disk guard: an explicit MYSQL_DATADIR is the path that is measured" {
  write_config "MYSQL_DATADIR='/srv/mysql'"
  run_rt
  [ "$status" -eq 0 ]
  grep -q '^df -Pk /srv/mysql' "$STUB_LOG"
}

# --- Memory guard ---

no_scratch_sql() { ! grep -q 'CREATE DATABASE\|DROP DATABASE\|mysql IMPORT' "$STUB_LOG"; }
failed_with_alert() {
  grep -q 'ALERT subject=\[devnel-backup\] RESTORE TEST FAILED' "$STUB_LOG"
  grep -q 'restore-uuid/fail' "$STUB_LOG"
}

@test "memory: low headroom at the pre-check fails before any scratch SQL, with alert and /fail" {
  write_meminfo 1000 400
  run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"not enough free memory for restore test: 1400 MB available (RAM + swap), 1536 MB required"* ]]
  no_scratch_sql
  failed_with_alert
}

@test "memory: enough headroom passes, counting swap, and logs the headroom line" {
  write_meminfo 1000 600
  run_rt
  [ "$status" -eq 0 ]
  [[ "$output" == *"memory headroom at start: 1600 MB"* ]]
  [[ "$output" == *"memory headroom: 1600 MB at start, lowest 1600 MB during import"* ]]
}

@test "memory: the start threshold is configurable" {
  write_meminfo 3000 0
  write_config "RESTORE_MIN_MEM_MB=4000" "RESTORE_ABORT_MEM_MB=100"
  run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"3000 MB available (RAM + swap), 4000 MB required"* ]]
  write_config "RESTORE_MIN_MEM_MB=2500" "RESTORE_ABORT_MEM_MB=100"
  run_rt
  [ "$status" -eq 0 ]
}

@test "memory: RESTORE_MIN_MEM_MB=0 skips the pre-check" {
  write_meminfo 10 0
  write_config "RESTORE_MIN_MEM_MB=0" "RESTORE_ABORT_MEM_MB=0"
  run_rt
  [ "$status" -eq 0 ]
  [[ "$output" == *"memory pre-check disabled"* ]]
}

@test "memory: unreadable meminfo fails closed before any scratch SQL" {
  rm -f "$MEMINFO_FILE"
  run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot read MemAvailable and SwapFree"* ]]
  no_scratch_sql
  failed_with_alert
}

@test "memory: meminfo without the fields fails closed before any scratch SQL" {
  printf 'MemTotal: 16000000 kB\nMemAvailable: 9000000 kB\n' >"$MEMINFO_FILE"
  run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot read MemAvailable and SwapFree"* ]]
  no_scratch_sql
}

@test "memory: invalid settings are rejected before any SQL" {
  write_config "RESTORE_MIN_MEM_MB=lots"
  run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"RESTORE_MIN_MEM_MB must be a non-negative integer"* ]]
  write_config "RESTORE_ABORT_MEM_MB=-5"
  run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"RESTORE_ABORT_MEM_MB must be a non-negative integer"* ]]
  write_config "RESTORE_MEM_POLL_SECONDS=0"
  run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"RESTORE_MEM_POLL_SECONDS must be a positive integer"* ]]
  write_config "RESTORE_MIN_MEM_MB=500" "RESTORE_ABORT_MEM_MB=500"
  run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be less than RESTORE_MIN_MEM_MB"* ]]
  no_scratch_sql
}

@test "memory: a zero abort floor is allowed with any start threshold" {
  write_config "RESTORE_MIN_MEM_MB=500" "RESTORE_ABORT_MEM_MB=0"
  run_rt
  [ "$status" -eq 0 ]
  [[ "$output" == *"import not monitored"* ]]
}

@test "watchdog: low memory during the import kills it, fails with the reason, and still drops the scratch DB" {
  write_config "RESTORE_MEM_POLL_SECONDS=1"
  export STUB_MYSQL_IMPORT_SLEEP=30 STUB_MYSQL_PIDFILE="$BATS_TEST_TMPDIR/import.pids"
  export STUB_MYSQL_IMPORT_MEMINFO="$MEMINFO_FILE"
  export STUB_MYSQL_IMPORT_MEMINFO_TEXT='MemAvailable: 204800 kB\nSwapFree: 102400 kB\n'
  local start=$SECONDS
  run_rt
  [ "$status" -ne 0 ]
  [ $((SECONDS - start)) -lt 15 ]
  [[ "$output" == *"import aborted: memory headroom fell to 300 MB (floor 512 MB)"* ]]
  [ "$(grep -c 'DROP DATABASE IF EXISTS `devnel_blog_restoretest`' "$STUB_LOG")" -ge 2 ]
  failed_with_alert
  grep -q 'ALERT .*body=import aborted: memory headroom fell to 300 MB' "$STUB_LOG"
  # the stub and its sleep were killed, nothing is left running
  read -r stub_pid sleep_pid <"$STUB_MYSQL_PIDFILE"
  ! kill -0 "$stub_pid" 2>/dev/null || false
  ! kill -0 "$sleep_pid" 2>/dev/null || false
}

@test "watchdog: a normal import is not failed by watchdog teardown and logs the lowest headroom" {
  write_meminfo 2000 100
  write_config "RESTORE_MEM_POLL_SECONDS=1"
  run_rt
  [ "$status" -eq 0 ]
  [[ "$output" == *"memory headroom: 2100 MB at start, lowest 2100 MB during import (abort floor 512 MB)"* ]]
  ! grep -q 'restore-uuid/fail' "$STUB_LOG" || false
  grep -q 'curl https://hc.example.test/ping/restore-uuid$' "$STUB_LOG"
}

@test "watchdog: an import that fails by itself still fails with its own error" {
  STUB_MYSQL_IMPORT_RC=1 run_rt
  [ "$status" -ne 0 ]
  [[ "$output" != *"import aborted"* ]]
  [[ "$output" == *"import into devnel_blog_restoretest failed (exit 1)"* ]]
  grep -q 'ALERT .*body=import into devnel_blog_restoretest failed (exit 1)' "$STUB_LOG"
  failed_with_alert
}

@test "watchdog: an import that fails by itself also reports it with the watchdog off" {
  write_config "RESTORE_ABORT_MEM_MB=0"
  STUB_MYSQL_IMPORT_RC=1 run_rt
  [ "$status" -ne 0 ]
  grep -q 'ALERT .*body=import into devnel_blog_restoretest failed (exit 1)' "$STUB_LOG"
}

@test "memory: leading zeros are rejected, not read as octal" {
  write_config "RESTORE_MIN_MEM_MB=0900"
  run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"RESTORE_MIN_MEM_MB must be a non-negative integer without leading zeros"* ]]
  write_config "RESTORE_ABORT_MEM_MB=0512"
  run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"RESTORE_ABORT_MEM_MB must be a non-negative integer without leading zeros"* ]]
  write_config "RESTORE_MEM_POLL_SECONDS=02"
  run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"RESTORE_MEM_POLL_SECONDS must be a positive integer without leading zeros"* ]]
  no_scratch_sql
}

@test "watchdog: fails closed at startup when pgrep is missing" {
  PGREP_BIN=no-such-pgrep-binary run_rt
  [ "$status" -ne 0 ]
  [[ "$output" == *"pgrep is required for the import watchdog"* ]]
  no_scratch_sql
  # not needed when the watchdog is off
  write_config "RESTORE_ABORT_MEM_MB=0"
  PGREP_BIN=no-such-pgrep-binary run_rt
  [ "$status" -eq 0 ]
}

@test "watchdog: meminfo losing its fields during the import aborts it and drops the scratch DB" {
  write_config "RESTORE_MEM_POLL_SECONDS=1"
  export STUB_MYSQL_IMPORT_SLEEP=30 STUB_MYSQL_PIDFILE="$BATS_TEST_TMPDIR/import.pids"
  export STUB_MYSQL_IMPORT_MEMINFO="$MEMINFO_FILE"
  export STUB_MYSQL_IMPORT_MEMINFO_TEXT='MemTotal: 16000000 kB\n'
  local start=$SECONDS
  run_rt
  [ "$status" -ne 0 ]
  [ $((SECONDS - start)) -lt 15 ]
  [[ "$output" == *"import aborted: cannot read MemAvailable and SwapFree"* ]]
  [ "$(grep -c 'DROP DATABASE IF EXISTS `devnel_blog_restoretest`' "$STUB_LOG")" -ge 2 ]
  failed_with_alert
  read -r stub_pid sleep_pid <"$STUB_MYSQL_PIDFILE"
  ! kill -0 "$stub_pid" 2>/dev/null || false
  ! kill -0 "$sleep_pid" 2>/dev/null || false
}

@test "signal: TERM during the import kills it, drops the scratch DB and alerts with the signal" {
  write_config "RESTORE_MEM_POLL_SECONDS=1"
  export STUB_MYSQL_IMPORT_SLEEP=30 STUB_MYSQL_PIDFILE="$BATS_TEST_TMPDIR/import.pids"
  "$RESTORE_SH" test >"$BATS_TEST_TMPDIR/out.log" 2>&1 &
  local pid=$! i
  for i in $(seq 1 100); do [ -s "$STUB_MYSQL_PIDFILE" ] && break; sleep 0.1; done
  [ -s "$STUB_MYSQL_PIDFILE" ]
  kill -TERM "$pid"
  local rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  grep -q 'interrupted by signal TERM' "$BATS_TEST_TMPDIR/out.log"
  [ "$(grep -c 'DROP DATABASE IF EXISTS `devnel_blog_restoretest`' "$STUB_LOG")" -ge 2 ]
  grep -q 'ALERT .*body=interrupted by signal TERM' "$STUB_LOG"
  grep -q 'restore-uuid/fail' "$STUB_LOG"
  read -r stub_pid sleep_pid <"$STUB_MYSQL_PIDFILE"
  ! kill -0 "$stub_pid" 2>/dev/null || false
  ! kill -0 "$sleep_pid" 2>/dev/null || false
}
