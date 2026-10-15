#!/usr/bin/env bats
# Tests for scripts/backup/backup.sh with stubbed mysqldump, gzip, rclone, curl, wp and df.

load backup_helper

setup() { backup_setup; }

run_db() { run "$BACKUP_SH" test db; }
run_files() { run "$BACKUP_SH" test files; }

@test "db success: valid dump, first line is -- MySQL dump, marker, off-site copy, heartbeat" {
  run_db
  [ "$status" -eq 0 ]
  dump="$(ls "$BACKUP_DIR"/*_database.sql.gz)"
  gzip -t "$dump"
  [ "$(gzip -dc "$dump" | sed -n 1p | cut -c1-13)" = "-- MySQL dump" ]
  grep -q '^db_file=' "$BACKUP_DIR/last-success"
  grep -q "^db_sha256=$(shasum -a 256 "$dump" | cut -d' ' -f1)" "$BACKUP_DIR/last-success"
  grep -q "rclone copyto $dump devnel-crypt:devnel.blog/db/" "$STUB_LOG"
  grep -q 'curl https://hc.example.test/ping/db-uuid/start' "$STUB_LOG"
  grep -q 'curl https://hc.example.test/ping/db-uuid$' "$STUB_LOG"
  ! grep -q '/fail' "$STUB_LOG"
  # no temp files left behind
  [ -z "$(find "$BACKUP_DIR" -name '.tmp.*')" ]
}

@test "db: credentials go through --defaults-extra-file, never on the command line" {
  run_db
  [ "$status" -eq 0 ]
  line="$(grep '^mysqldump ' "$STUB_LOG")"
  [[ "$line" == "mysqldump --defaults-extra-file="* ]]
  [[ "$line" != *s3cret* ]]
  [[ "$line" != *" -p"* ]]
  [[ "$line" == *"--single-transaction"* && "$line" == *"--routines"* && "$line" == *"--triggers"* ]]
  [[ "$line" == *"--default-character-set=utf8mb4"* ]]
}

@test "mysqldump failure: no dump file, existing good dump untouched, alert, /fail ping, non-zero, no marker update" {
  mkdir -p "$BACKUP_DIR"
  echo good | gzip >"$BACKUP_DIR/20260101000000_database.sql.gz"
  cp "$BACKUP_DIR/20260101000000_database.sql.gz" "$BATS_TEST_TMPDIR/good.gz"
  STUB_MYSQLDUMP_FAIL=1 run_db
  [ "$status" -ne 0 ]
  [ "$(backup_files_list)" = "$BACKUP_DIR/20260101000000_database.sql.gz" ]
  cmp "$BACKUP_DIR/20260101000000_database.sql.gz" "$BATS_TEST_TMPDIR/good.gz"
  [ ! -e "$BACKUP_DIR/last-success" ]
  grep -q 'ALERT subject=\[devnel-backup\] FAILED: test db' "$STUB_LOG"
  grep -q 'curl https://hc.example.test/ping/db-uuid/fail' "$STUB_LOG"
  ! grep -q 'rclone copyto' "$STUB_LOG"
}

@test "dump whose first line is not -- MySQL dump is rejected (the old stderr-in-dump bug)" {
  STUB_MYSQLDUMP_BADHEADER=1 run_db
  [ "$status" -ne 0 ]
  [ -z "$(backup_files_list)" ]
  [[ "$output" == *"does not start with '-- MySQL dump'"* ]]
}

@test "truncated dump (no trailer) is rejected" {
  STUB_MYSQLDUMP_TRUNCATED=1 run_db
  [ "$status" -ne 0 ]
  [ -z "$(backup_files_list)" ]
  [[ "$output" == *"incomplete"* ]]
}

@test "corrupt gzip is detected and nothing is kept" {
  STUB_GZIP_CORRUPT=1 run_db
  [ "$status" -ne 0 ]
  [ -z "$(backup_files_list)" ]
  [ ! -e "$BACKUP_DIR/last-success" ]
  [[ "$output" == *"not a valid gzip"* ]]
}

@test "low disk aborts before dumping, alerts, and writes nothing" {
  mkdir -p "$BACKUP_DIR"
  head -c 3000000 /dev/zero >"$BACKUP_DIR/20260102000000_database.sql.gz"
  STUB_DF_AVAIL_KB=100 run_db
  [ "$status" -ne 0 ]
  ! grep -q '^mysqldump ' "$STUB_LOG"
  [ ! -e "$BACKUP_DIR/last-success" ]
  grep -q 'ALERT subject=\[devnel-backup\] FAILED' "$STUB_LOG"
  [[ "$output" == *"not enough free disk"* ]]
}

@test "disk check requires 2x the last dump size" {
  mkdir -p "$BACKUP_DIR"
  head -c 3145728 /dev/zero >"$BACKUP_DIR/20260102000000_database.sql.gz" # 3072 KB
  STUB_DF_AVAIL_KB=6000 run_db
  [ "$status" -ne 0 ]
  STUB_DF_AVAIL_KB=6200 run_db
  [ "$status" -eq 0 ]
}

@test "retention deletes old db dumps, keeps recent ones and other file types" {
  mkdir -p "$BACKUP_DIR"
  for n in 20260101000001 20260102000002 20260103000003; do echo x >"$BACKUP_DIR/${n}_database.sql.gz"; done
  touch_days_old 30 "$BACKUP_DIR/20260101000001_database.sql.gz"
  touch_days_old 15 "$BACKUP_DIR/20260102000002_database.sql.gz"
  touch_days_old 13 "$BACKUP_DIR/20260103000003_database.sql.gz"
  echo x >"$BACKUP_DIR/20260101_files.tar.gz"
  touch_days_old 90 "$BACKUP_DIR/20260101_files.tar.gz"
  run_db
  [ "$status" -eq 0 ]
  [ ! -e "$BACKUP_DIR/20260101000001_database.sql.gz" ]
  [ ! -e "$BACKUP_DIR/20260102000002_database.sql.gz" ]
  [ -e "$BACKUP_DIR/20260103000003_database.sql.gz" ]
  [ -e "$BACKUP_DIR/20260101_files.tar.gz" ] # a db run never prunes files archives
  [ "$(ls "$BACKUP_DIR"/*_database.sql.gz | wc -l | tr -d ' ')" -eq 2 ]
}

@test "retention honours configured days" {
  write_config "LOCAL_RETENTION_DB_DAYS=3"
  mkdir -p "$BACKUP_DIR"
  echo x >"$BACKUP_DIR/20260101000001_database.sql.gz"
  touch_days_old 4 "$BACKUP_DIR/20260101000001_database.sql.gz"
  run_db
  [ "$status" -eq 0 ]
  [ ! -e "$BACKUP_DIR/20260101000001_database.sql.gz" ]
}

@test "retention does not run when the backup fails" {
  mkdir -p "$BACKUP_DIR"
  echo x >"$BACKUP_DIR/20260101000001_database.sql.gz"
  touch_days_old 60 "$BACKUP_DIR/20260101000001_database.sql.gz"
  STUB_MYSQLDUMP_FAIL=1 run_db
  [ "$status" -ne 0 ]
  [ -e "$BACKUP_DIR/20260101000001_database.sql.gz" ]
}

@test "off-site pruning uses min-age, bypasses the Drive trash, and targets the db folder" {
  run_db
  [ "$status" -eq 0 ]
  grep -q 'rclone delete --min-age 90d --drive-use-trash=false devnel-crypt:devnel.blog/db' "$STUB_LOG"
}

@test "off-site copy failure fails the run, keeps the good local dump, no marker, alert" {
  STUB_RCLONE_FAIL=1 run_db
  [ "$status" -ne 0 ]
  [ -e "$(ls "$BACKUP_DIR"/*_database.sql.gz)" ]
  [ ! -e "$BACKUP_DIR/last-success" ]
  ! grep -q 'rclone delete' "$STUB_LOG"
  grep -q 'ALERT subject=\[devnel-backup\] FAILED: test db' "$STUB_LOG"
  grep -q '/fail' "$STUB_LOG"
}

@test "heartbeat host being down does not fail the backup" {
  STUB_CURL_FAIL=1 run_db
  [ "$status" -eq 0 ]
  [ -e "$BACKUP_DIR/last-success" ]
}

@test "marker is written only on success and keeps the other kind's keys" {
  run_db
  [ "$status" -eq 0 ]
  run_files
  [ "$status" -eq 0 ]
  grep -q '^db_file=' "$BACKUP_DIR/last-success"
  grep -q '^files_file=' "$BACKUP_DIR/last-success"
  [ "$(stat -c %a "$BACKUP_DIR/last-success" 2>/dev/null || stat -f %Lp "$BACKUP_DIR/last-success")" = 600 ]
  before="$(cat "$BACKUP_DIR/last-success")"
  STUB_MYSQLDUMP_FAIL=1 run_db
  [ "$status" -ne 0 ]
  [ "$(cat "$BACKUP_DIR/last-success")" = "$before" ]
}

@test "files: archives wp-content without cache, copies nginx conf, prunes by files retention" {
  mkdir -p "$BACKUP_DIR"
  echo x >"$BACKUP_DIR/20260101000000_files.tar.gz"
  touch_days_old 70 "$BACKUP_DIR/20260101000000_files.tar.gz"
  echo x >"$BACKUP_DIR/20260101000000_nginx.conf"
  touch_days_old 70 "$BACKUP_DIR/20260101000000_nginx.conf"
  run_files
  [ "$status" -eq 0 ]
  [ ! -e "$BACKUP_DIR/20260101000000_files.tar.gz" ]
  [ ! -e "$BACKUP_DIR/20260101000000_nginx.conf" ]
  archive="$(ls "$BACKUP_DIR"/*_files.tar.gz)"
  tar -tzf "$archive" | grep -q 'wp-content/uploads/a.txt'
  ! tar -tzf "$archive" | grep -q 'wp-content/cache'
  ! tar -tzf "$archive" | grep -q 'wp-config'
  grep -q 'server {}' "$BACKUP_DIR"/*_nginx.conf
  grep -q 'rclone copyto .*_files.tar.gz devnel-crypt:devnel.blog/files/' "$STUB_LOG"
  grep -q 'rclone copyto .*_nginx.conf devnel-crypt:devnel.blog/nginx/' "$STUB_LOG"
  grep -q 'rclone delete --min-age 182d' "$STUB_LOG"
  grep -q 'curl https://hc.example.test/ping/files-uuid$' "$STUB_LOG"
}

@test "config file that is not mode 600 is refused" {
  chmod 644 "$DEVNEL_BACKUP_CONFIG_DIR/test.env"
  run_db
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be mode 600"* ]]
  ! grep -q '^mysqldump ' "$STUB_LOG"
}

@test "DB defaults file that is not mode 600 is refused" {
  chmod 644 "$BATS_TEST_TMPDIR/prod.my.cnf"
  run_db
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be mode 600"* ]]
  ! grep -q '^mysqldump ' "$STUB_LOG"
}

@test "invalid retention value and bad arguments are rejected" {
  write_config "LOCAL_RETENTION_DB_DAYS=0"
  run_db
  [ "$status" -ne 0 ]
  run "$BACKUP_SH" test everything
  [ "$status" -eq 64 ]
  run "$BACKUP_SH" '../evil' db
  [ "$status" -ne 0 ]
}

@test "stale temp files from a killed run are cleaned, fresh ones kept" {
  mkdir -p "$BACKUP_DIR"
  echo x >"$BACKUP_DIR/.tmp.111.database.sql.gz"
  echo x >"$BACKUP_DIR/.tmp.222.database.sql.gz"
  touch_days_old 3 "$BACKUP_DIR/.tmp.111.database.sql.gz"
  run_db
  [ "$status" -eq 0 ]
  [ ! -e "$BACKUP_DIR/.tmp.111.database.sql.gz" ]
  [ -e "$BACKUP_DIR/.tmp.222.database.sql.gz" ]
}

@test "LOG_FILE unset in the config defaults to <parent of SITE_ROOT>/logs/backup.log" {
  NO_LOG_FILE=1 write_config
  run_db
  [ "$status" -eq 0 ]
  grep -q 'dumping' "$BATS_TEST_TMPDIR/site/logs/backup.log"
}

@test "files run with NGINX_CONF empty does not prune or touch the nginx remote dir" {
  write_config "NGINX_CONF=''"
  STUB_RCLONE_DELETE_RC_nginx=3 run_files
  [ "$status" -eq 0 ]
  ! grep -q 'devnel.blog/nginx' "$STUB_LOG"
  grep -q 'rclone delete .* devnel-crypt:devnel.blog/files' "$STUB_LOG"
}

@test "off-site prune of a directory that does not exist yet (rclone exit 3) is not a failure" {
  STUB_RCLONE_DELETE_RC_files=3 run_files
  [ "$status" -eq 0 ]
  [ -e "$BACKUP_DIR/last-success" ]
  [[ "$output" == *"nothing to prune"* ]]
}

@test "off-site prune failing for another reason still fails the run" {
  STUB_RCLONE_DELETE_RC_db=5 run_db
  [ "$status" -ne 0 ]
  grep -q '/fail' "$STUB_LOG"
}

@test "scripts contain no password" {
  ! grep -rEi "(-p[\$\"']|DB_PASSWORD|password=)" "$REPO_ROOT/scripts/backup"
}

@test "fresh run under a permissive umask: BACKUP_DIR is 700, dump, marker, log are 600" {
  umask 022
  rm -rf "$BACKUP_DIR"
  run_db
  [ "$status" -eq 0 ]
  [ "$(mode_of "$BACKUP_DIR")" = 700 ]
  [ "$(mode_of "$(ls "$BACKUP_DIR"/*_database.sql.gz)")" = 600 ]
  [ "$(mode_of "$BACKUP_DIR/last-success")" = 600 ]
  [ "$(mode_of "$BATS_TEST_TMPDIR/site/backup.log")" = 600 ]
}

@test "an existing world-readable BACKUP_DIR is tightened to 700; files archive and nginx copy are 600" {
  umask 022
  mkdir -p "$BACKUP_DIR"
  chmod 755 "$BACKUP_DIR"
  run_files
  [ "$status" -eq 0 ]
  [ "$(mode_of "$BACKUP_DIR")" = 700 ]
  [ "$(mode_of "$(ls "$BACKUP_DIR"/*_files.tar.gz)")" = 600 ]
  [ "$(mode_of "$(ls "$BACKUP_DIR"/*_nginx.conf)")" = 600 ]
}

@test "files disk check ignores the directories tar excludes" {
  mkdir -p "$SITE_ROOT/wp-content/updraft" "$SITE_ROOT/wp-content/upgrade"
  head -c 6000000 /dev/zero >"$SITE_ROOT/wp-content/updraft/old-backup.zip"
  head -c 3000000 /dev/zero >"$SITE_ROOT/wp-content/upgrade/x.zip"
  # The real content is a few KB; counting the excluded 9 MB would need > 17000 KB free.
  STUB_DF_AVAIL_KB=500 run_files
  [ "$status" -eq 0 ]
  ! tar -tzf "$(ls "$BACKUP_DIR"/*_files.tar.gz)" | grep -q updraft
}

@test "files disk check still aborts when the included content does not fit" {
  head -c 6000000 /dev/zero >"$SITE_ROOT/wp-content/uploads/big.bin"
  STUB_DF_AVAIL_KB=9000 run_files   # needs 2 x ~5860 KB
  [ "$status" -ne 0 ]
  [[ "$output" == *"not enough free disk"* ]]
  [ -z "$(backup_files_list)" ]
}
