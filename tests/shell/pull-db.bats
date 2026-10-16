#!/usr/bin/env bats
# Tests for scripts/pull-db.sh with stubbed ssh, docker, npx (wp-env), git and gzip.
# The real SQL is tested against MySQL in sanitise-integration.bats.

load pull_helper

setup() { pull_setup; }

run_pull() { run "$PULL"; }

# --- the stream goes into an isolated, throwaway container --------------------------------------

@test "success: exit 0, summary printed, wp-env imported" {
  run_pull
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"published posts: 7"* ]]
  [[ "$output" == *"admin / password"* ]]
  grep -q '^wp-env wp db import - ' "$STUB_LOG"
}

@test "the container is isolated: --network none, no published ports, mysql:8.4, random name, in-memory data" {
  run_pull
  [ "$status" -eq 0 ]
  line="$(grep '^docker run ' "$STUB_LOG")"
  [[ "$line" == *"--network none"* ]]
  [[ "$line" == *" mysql:8.4 "* ]]
  [[ "$line" == *"--tmpfs /var/lib/mysql"* ]]
  [[ "$line" == *"--tmpfs /tmp "* ]]
  [[ "$line" != *" -p "* && "$line" != *" -p"[0-9]* && "$line" != *"--publish"* && "$line" != *" -P "* ]]
  [[ "$(container_name)" =~ ^devnel-sanitise-[0-9a-f]{12}$ ]]
  # a different name on the next run
  first="$(container_name)"
  : >"$STUB_LOG"
  run_pull
  [ "$(container_name)" != "$first" ]
}

@test "the ssh export is the one read-only command, streamed into docker exec on the container" {
  run_pull
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ssh ' "$STUB_LOG")" -eq 1 ]
  grep -qxF 'ssh triton.devnel.com cd ~/devnel.blog/public && wp db export - --single-transaction' "$STUB_LOG"
  grep -q '^container stream$' "$STUB_LOG"
  # the stream goes through docker exec -i into the named container, never to a file
  grep -q "^docker exec -i $(container_name) mysql " "$STUB_LOG"
}

@test "sanitise SQL is applied, and checked, before any export, and the export before any wp-env import" {
  run_pull
  [ "$status" -eq 0 ]
  stream="$(line_no '^container stream$')"
  sanitise="$(line_no '^container sanitise$')"
  truncate="$(line_no '^container sanitise-truncate$')"
  check="$(line_no '^container check$')"
  dump="$(line_no 'mysqldump')"
  import="$(line_no '^wp-env wp db import')"
  [ -n "$stream" ] && [ -n "$sanitise" ] && [ -n "$check" ] && [ -n "$dump" ] && [ -n "$import" ]
  [ "$stream" -lt "$sanitise" ]
  [ "$sanitise" -lt "$check" ]
  [ "$check" -lt "$dump" ]
  [ "$dump" -lt "$import" ]
}

@test "the sanitise SQL that runs covers users, usermeta, comments, commentmeta and options" {
  run_pull
  [ "$status" -eq 0 ]
  sql="$(cat "$STUB_SQL_DIR"/sql-*-sanitise.sql)"
  [[ "$sql" == *"UPDATE \`wp_users\` SET user_email = CONCAT('user', ID, '@example.test')"* ]]
  [[ "$sql" == *"user_activation_key = ''"* ]]
  [[ "$sql" == *"DELETE FROM \`wp_usermeta\`"*"session_tokens"* ]]
  [[ "$sql" == *"UPDATE \`wp_comments\` SET comment_author_email = CONCAT('commenter', comment_ID, '@example.test'), comment_author_IP = '127.0.0.1', comment_agent = ''"* ]]
  [[ "$sql" == *"DELETE FROM \`wp_commentmeta\`"* ]]
  [[ "$sql" == *"DELETE FROM \`wp_options\`"*"activitypub_application_keypair"*"updraft_s3"* ]]
  [[ "$sql" == *"SET option_value = 'admin@example.test' WHERE option_name IN ('admin_email'"* ]]
}

@test "the truncate list is applied to the tables that exist" {
  STUB_TRUNC_TABLES='wp_post_smtp_logs\nwp_zbs_contacts' run_pull
  [ "$status" -eq 0 ]
  sql="$(cat "$STUB_SQL_DIR"/sql-*-truncate.sql)"
  [[ "$sql" == *'TRUNCATE TABLE `wp_post_smtp_logs`;'* ]]
  [[ "$sql" == *'TRUNCATE TABLE `wp_zbs_contacts`;'* ]]
}

# --- failure leaves wp-env untouched and removes the container -----------------------------------

@test "check failure in the container aborts before the export and any wp-env import" {
  STUB_CHECK_OUTPUT_container='email wp_users.user_email' run_pull
  [ "$status" -ne 0 ]
  [[ "$output" == *"email wp_users.user_email"* ]]
  [[ "$output" == *"failed the check"* ]]
  ! grep -q 'mysqldump' "$STUB_LOG" || false
  nothing_in_wpenv
  ! grep -q '^wp-env wp db import' "$STUB_LOG" || false
  [ -z "$(find "$DATA" -name 'sanitised-*' 2>/dev/null)" ]
  container_removed
}

@test "a failing sanitise step aborts before the check and the export, with wp-env untouched" {
  STUB_SANITISE_RC=1 run_pull
  [ "$status" -ne 0 ]
  [[ "$output" == *"sanitising failed"* ]]
  ! grep -q '^container check$' "$STUB_LOG" || false
  ! grep -q 'mysqldump' "$STUB_LOG" || false
  nothing_in_wpenv
  container_removed
}

@test "ssh failure: non-zero, container removed, wp-env untouched, no snapshot" {
  STUB_SSH_RC=255 run_pull
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing was imported into wp-env"* ]]
  container_removed
  nothing_in_wpenv
  ! grep -q 'mysqldump' "$STUB_LOG" || false
  ! grep -q '^container sanitise' "$STUB_LOG" || false
  [ -z "$(find "$DATA" -name 'sanitised-*' 2>/dev/null)" ]
}

@test "a failing import into the container (broken stream) is a failure with wp-env untouched" {
  STUB_IMPORT_RC=1 run_pull
  [ "$status" -ne 0 ]
  container_removed
  nothing_in_wpenv
  ! grep -q 'mysqldump' "$STUB_LOG" || false
}

@test "an empty import is refused" {
  STUB_POSTS=0 run_pull
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty"* ]]
  container_removed
  nothing_in_wpenv
}

@test "the container never becoming ready fails and removes it" {
  STUB_PING_FAIL=1 run_pull
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not become ready"* ]]
  container_removed
  ! grep -q '^ssh ' "$STUB_LOG" || false
  nothing_in_wpenv
}

@test "docker run failing fails cleanly without talking to production" {
  STUB_DOCKER_RUN_FAIL=1 run_pull
  [ "$status" -ne 0 ]
  # a half-created container is still removed by the trap
  container_removed
  ! grep -q '^ssh ' "$STUB_LOG" || false
  nothing_in_wpenv
}

@test "a failing sanitised export removes the container and leaves no snapshot or temp file" {
  STUB_DUMP_FAIL=1 run_pull
  [ "$status" -ne 0 ]
  container_removed
  nothing_in_wpenv
  [ -z "$(find "$DATA" -type f 2>/dev/null)" ]
}

@test "the container is removed on the success path too, before the wp-env import" {
  run_pull
  [ "$status" -eq 0 ]
  container_removed
  rm_line="$(line_no "^docker rm -f -v $(container_name)\$")"
  import="$(line_no '^wp-env wp db import')"
  [ "$rm_line" -lt "$import" ]
  # removed exactly once: the trap finds nothing left to remove
  [ "$(grep -c "^docker rm " "$STUB_LOG")" -eq 1 ]
}

@test "a failing wp-env import still exits non-zero and the container is already gone" {
  STUB_WPENV_FAIL_AT='db import' run_pull
  [ "$status" -ne 0 ]
  [[ "$output" == *"importing into wp-env failed"* ]]
  container_removed
}

@test "SIGTERM mid-stream removes the container" {
  STUB_SSH_SLEEP=2 "$PULL" >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do
    grep -q '^ssh ' "$STUB_LOG" && break
    sleep 0.1
  done
  kill -TERM "$pid"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  container_removed
  nothing_in_wpenv
}

@test "wp-env not running: fails before starting a container or touching production" {
  STUB_WPENV_DOWN=1 run_pull
  [ "$status" -ne 0 ]
  [[ "$output" == *"wp-env is not running"* ]]
  ! grep -q '^docker run' "$STUB_LOG" || false
  ! grep -q '^ssh ' "$STUB_LOG" || false
}

@test "docker not running: fails before touching production" {
  STUB_DOCKER_DOWN=1 run_pull
  [ "$status" -ne 0 ]
  [[ "$output" == *"docker is not running"* ]]
  ! grep -q '^ssh ' "$STUB_LOG" || false
}

# --- after the import ----------------------------------------------------------------------------

@test "search-replace rewrites URLs only, with the documented arguments, then flushes permalinks" {
  run_pull
  [ "$status" -eq 0 ]
  grep -qxF 'wp-env wp search-replace https://devnel.blog http://localhost:8888 --all-tables --precise' "$STUB_LOG"
  [ "$(grep -c '^wp-env wp search-replace' "$STUB_LOG")" -eq 1 ]
  sr="$(line_no '^wp-env wp search-replace')"
  flush="$(line_no '^wp-env wp rewrite flush')"
  [ "$sr" -lt "$flush" ]
}

@test "a local admin is created, or reset when it exists" {
  run_pull
  [ "$status" -eq 0 ]
  grep -q '^wp-env wp user create admin admin@example.test --role=administrator --user_pass=password' "$STUB_LOG"
  : >"$STUB_LOG"
  STUB_ADMIN_EXISTS=1 run_pull
  [ "$status" -eq 0 ]
  grep -q '^wp-env wp user update admin --user_pass=password --role=administrator' "$STUB_LOG"
  ! grep -q '^wp-env wp user create' "$STUB_LOG" || false
}

@test "the production-only plugins are deactivated; one that is not installed locally is not an error" {
  STUB_NOT_ACTIVE="updraftplus" run_pull
  [ "$status" -eq 0 ]
  for p in worker post-smtp updraftplus nginx-cache redis-cache; do
    grep -qxF "wp-env wp plugin deactivate $p" "$STUB_LOG"
  done
}

@test "options WordPress or plugins write locally are deleted again just before the final wp-env check" {
  STUB_PRESENT_OPTIONS='_transient_x' run_pull
  [ "$status" -eq 0 ]
  cleanup="$(line_no '^wpenv sanitise-options$')"
  wpenv_check="$(line_no '^wpenv check$')"
  deactivate="$(line_no '^wp-env wp plugin deactivate')"
  [ -n "$cleanup" ]
  [ "$deactivate" -lt "$cleanup" ]
  [ "$cleanup" -lt "$wpenv_check" ]
  sql="$(cat "$STUB_SQL_DIR"/sql-*-options.sql)"
  [[ "$sql" == *"DELETE FROM \`wp_options\`"*"_transient"* ]]
  # only options are touched
  [[ "$sql" != *"wp_users"* && "$sql" != *"wp_posts"* ]]
}

@test "check-sanitised runs against the container and again against wp-env at the end" {
  run_pull
  [ "$status" -eq 0 ]
  container_check="$(line_no '^container check$')"
  wpenv_check="$(line_no '^wpenv check$')"
  import="$(line_no '^wp-env wp db import')"
  flush="$(line_no '^wp-env wp rewrite flush')"
  [ -n "$wpenv_check" ]
  [ "$container_check" -lt "$import" ]
  [ "$flush" -lt "$wpenv_check" ]
}

@test "a failing wp-env check makes the pull fail" {
  STUB_CHECK_OUTPUT_wpenv='option fs_accounts' run_pull
  [ "$status" -ne 0 ]
  [[ "$output" == *"option fs_accounts"* ]]
  [[ "$output" == *"wp-env failed the sanitisation check"* ]]
}

# --- files ---------------------------------------------------------------------------------------

@test "file modes: .data is 700 and the snapshot is 600, even under a permissive umask" {
  umask 000
  run_pull
  [ "$status" -eq 0 ]
  [ "$(mode_of "$DATA")" = 700 ]
  snap="$(ls "$DATA"/sanitised-*.sql.gz)"
  [ "$(mode_of "$snap")" = 600 ]
  gzip -t "$snap"
  [ "$(gzip -dc "$snap")" = "-- sanitised stub dump" ]
}

@test "an existing world-readable .data is tightened to 700" {
  mkdir -p "$DATA"
  chmod 755 "$DATA"
  run_pull
  [ "$status" -eq 0 ]
  [ "$(mode_of "$DATA")" = 700 ]
}

@test "no raw production dump is written anywhere: the only file is the sanitised snapshot" {
  run_pull
  [ "$status" -eq 0 ]
  [ "$(find "$DATA" -type f | wc -l | tr -d ' ')" -eq 1 ]
  [[ "$(find "$DATA" -type f)" == "$DATA"/sanitised-????????.sql.gz ]]
  ! grep -rl 'CREATE TABLE wp_posts (ID int)' "$BATS_TEST_TMPDIR" --include='*' 2>/dev/null | grep -v '/stub\.log$' | grep . || false
}

@test "snapshot pruning keeps the newest 3 and leaves other files alone" {
  mkdir -p "$DATA/uploads"
  echo keep >"$DATA/notes.txt"
  for d in 20200101 20200102 20200103 20200104; do echo old | gzip >"$DATA/sanitised-$d.sql.gz"; done
  run_pull
  [ "$status" -eq 0 ]
  run bash -c "ls '$DATA'/sanitised-*.sql.gz | wc -l | tr -d ' '"
  [ "$output" -eq 3 ]
  [ -f "$DATA/sanitised-20200104.sql.gz" ]
  [ -f "$DATA/sanitised-20200103.sql.gz" ]
  [ ! -f "$DATA/sanitised-20200101.sql.gz" ]
  [ ! -f "$DATA/sanitised-20200102.sql.gz" ]
  [ -f "$DATA/notes.txt" ]
  [ -d "$DATA/uploads" ]
}

@test "a run that fails does not prune existing snapshots" {
  mkdir -p "$DATA"
  for d in 20200101 20200102 20200103; do echo old | gzip >"$DATA/sanitised-$d.sql.gz"; done
  STUB_SSH_RC=1 run_pull
  [ "$status" -ne 0 ]
  [ "$(ls "$DATA"/sanitised-*.sql.gz | wc -l | tr -d ' ')" -eq 3 ]
}

@test "refuses to run when .data is not gitignored" {
  STUB_GIT_NOT_IGNORED=1 run_pull
  [ "$status" -ne 0 ]
  [[ "$output" == *"not gitignored"* ]]
  ! grep -q '^docker run' "$STUB_LOG" || false
  ! grep -q '^ssh ' "$STUB_LOG" || false
  grep -q '^git .*check-ignore' "$STUB_LOG"
}

@test "a data directory outside the repository needs no gitignore" {
  DEVNEL_DATA_DIR="$BATS_TEST_TMPDIR/elsewhere" STUB_GIT_NOT_IGNORED=1 run_pull
  [ "$status" -eq 0 ]
  [ "$(mode_of "$BATS_TEST_TMPDIR/elsewhere")" = 700 ]
}

@test "pull-db.sh copies nothing to or from production except through the one ssh export" {
  ! grep -nE '(^|[^a-z])(scp|rsync|sftp)[[:space:]]' "$SRC_ROOT/scripts/pull-db.sh" || false
}
