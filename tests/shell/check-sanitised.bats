#!/usr/bin/env bats
# Wiring tests for scripts/check-sanitised.sh with stubbed docker and wp-env. What the queries
# detect is tested against real MySQL in sanitise-integration.bats.

load pull_helper

setup() { pull_setup; }

@test "clean database: exit 0 and OK" {
  run "$CHECK" --container c1
  [ "$status" -eq 0 ]
  [[ "$output" == OK* ]]
}

@test "violations: exit 1, each reported once as <class> <table.column>, nothing else printed" {
  STUB_CHECK_OUTPUT='email wp_users.user_email\nip wp_comments.comment_author_IP\nemail wp_users.user_email' run "$CHECK" --container c1
  [ "$status" -eq 1 ]
  [[ "$output" == *"(2 problem(s))"* ]]
  [[ "$output" == *"  email wp_users.user_email"* ]]
  [[ "$output" == *"  ip wp_comments.comment_author_IP"* ]]
}

@test "--container runs the SQL with docker exec on that container; the default targets wp-env" {
  run "$CHECK" --container c1
  grep -q '^docker exec -i c1 mysql ' "$STUB_LOG"
  ! grep -q '^wp-env' "$STUB_LOG" || false
  : >"$STUB_LOG"
  run "$CHECK"
  [ "$status" -eq 0 ]
  grep -q '^wpenv check$' "$STUB_LOG"
  ! grep -q '^docker exec' "$STUB_LOG" || false
}

@test "--wp-env deletes the listed options first (transients written by normal use); --container never writes" {
  STUB_PRESENT_OPTIONS='_transient_feed\n_site_transient_update_core\nactivitypub_keypair_for_0' run "$CHECK"
  [ "$status" -eq 0 ]
  cleanup="$(line_no '^wpenv sanitise-options$')"
  check="$(line_no '^wpenv check$')"
  [ -n "$cleanup" ] && [ "$cleanup" -lt "$check" ]
  sql="$(cat "$STUB_SQL_DIR"/sql-*-options.sql)"
  [[ "$sql" == *"DELETE FROM \`wp_options\`"* && "$sql" == *"!_transient!_%"* ]]
  [[ "$sql" != *"wp_posts"* ]]
  : >"$STUB_LOG"
  # Options present, so a clearing container mode would show up in the log.
  STUB_PRESENT_OPTIONS='_transient_feed\nfs_accounts' run "$CHECK" --container c1
  [ "$status" -eq 0 ]
  ! grep -q 'sanitise-options' "$STUB_LOG" || false
}

@test "--wp-env prints the names it cleared (names only), and a transient or keypair raises no warning" {
  STUB_PRESENT_OPTIONS='_transient_feed\n_site_transient_update_core\nactivitypub_keypair_for_0' run "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cleared 3 locally regenerated option(s): _site_transient_update_core, _transient_feed, activitypub_keypair_for_0"* ||
    "$output" == *"cleared 3 locally regenerated option(s): _transient_feed, _site_transient_update_core, activitypub_keypair_for_0"* ]]
  [[ "$output" != *"WARNING"* ]]
}

@test "--wp-env warns when a cleared option is not a transient or an ActivityPub key pair" {
  STUB_PRESENT_OPTIONS='_transient_feed\nfs_accounts' run "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cleared 2 locally regenerated option(s)"* ]]
  [[ "$output" == *"fs_accounts"* ]]
  [[ "$output" == *"WARNING"* && "$output" == *"unsanitised data"* && "$output" == *"container pass"* ]]
}

@test "--wp-env says nothing about clearing when nothing was present" {
  run "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" != *"cleared"* ]]
}

@test "--wp-env --no-clear deletes nothing and reports a listed option as a failure" {
  STUB_PRESENT_OPTIONS='fs_accounts' STUB_CHECK_OUTPUT='option fs_accounts' run "$CHECK" --wp-env --no-clear
  [ "$status" -eq 1 ]
  [[ "$output" == *"  option fs_accounts"* ]]
  ! grep -q 'sanitise-options' "$STUB_LOG" || false
  ! grep -q 'present-options' "$STUB_LOG" || false
  grep -q '^wpenv check$' "$STUB_LOG"
}

@test "--no-clear is only for --wp-env, and extra arguments are rejected" {
  run "$CHECK" --container c1 --no-clear
  [ "$status" -eq 2 ]
  run "$CHECK" --no-clear
  [ "$status" -eq 2 ]
  run "$CHECK" --wp-env --no-clear extra
  [ "$status" -eq 2 ]
}

@test "the check queries cover IPs in usermeta, postmeta and options, and the encoded email forms" {
  STUB_COLUMNS='wp_options\toption_name\nwp_options\toption_value\nwp_usermeta\tmeta_value\nwp_postmeta\tmeta_value' run "$CHECK" --container c1
  [ "$status" -eq 0 ]
  sql="$(cat "$STUB_SQL_DIR"/sql-*-check.sql)"
  for t in wp_options.option_value wp_usermeta.meta_value wp_postmeta.meta_value; do
    [[ "$sql" == *"'ip $t'"* ]]
  done
  [[ "$sql" == *"%40"* && "$sql" == *"&#"* ]]
}

@test "the generated check SQL probes every class and every listed name" {
  STUB_COLUMNS='wp_options\toption_name\nwp_posts\tpost_content\nwp_usermeta\tmeta_key' run "$CHECK" --container c1
  [ "$status" -eq 0 ]
  sql="$(cat "$STUB_SQL_DIR"/sql-*-check.sql)"
  [[ "$sql" == *"'email wp_posts.post_content'"* ]]
  [[ "$sql" == *"'pem wp_posts.post_content'"* ]]
  [[ "$sql" == *"'option activitypub_application_keypair'"* ]]
  [[ "$sql" == *"'option updraft_s3'"* ]]
  [[ "$sql" == *"'option !_transient!_%'"* ]]
  # the check lists are the same files the sanitiser reads
  while IFS= read -r entry; do
    [[ -z "$entry" || "$entry" == "#"* ]] && continue
    [[ "$sql" == *"'option $entry'"* ]]
  done <"$SRC_ROOT/scripts/sanitise/options-delete.txt"
  while IFS= read -r entry; do
    [[ -z "$entry" || "$entry" == "#"* ]] && continue
    [[ "$sql" == *"'usermeta $entry'"* ]]
  done <"$SRC_ROOT/scripts/sanitise/usermeta-delete.txt"
}

@test "comments and commentmeta get the IP probes; other tables do not" {
  STUB_COLUMNS='wp_options\toption_name\nwp_comments\tcomment_author_IP\nwp_commentmeta\tmeta_value\nwp_posts\tpost_content' run "$CHECK" --container c1
  [ "$status" -eq 0 ]
  sql="$(cat "$STUB_SQL_DIR"/sql-*-check.sql)"
  [[ "$sql" == *"'ip wp_comments.comment_author_IP'"* ]]
  [[ "$sql" == *"'ip wp_commentmeta.meta_value'"* ]]
  [[ "$sql" != *"'ip wp_posts.post_content'"* ]]
}

@test "tables from the truncate list that exist get an emptiness probe" {
  STUB_TRUNC_TABLES='wp_zbs_contacts\nwp_redirection_404' run "$CHECK" --container c1
  sql="$(cat "$STUB_SQL_DIR"/sql-*-check.sql)"
  [[ "$sql" == *'SELECT '"'nonempty wp_zbs_contacts'"' FROM `wp_zbs_contacts`'* ]]
  [[ "$sql" == *"'nonempty wp_redirection_404'"* ]]
}

@test "no options table means the database isn't imported: refused, not passed" {
  STUB_COLUMNS='wp_posts\tpost_content' run "$CHECK" --container c1
  [ "$status" -eq 2 ]
  [[ "$output" == *"is the database imported"* ]]
}

@test "no columns at all (nothing running) is refused" {
  STUB_COLUMNS=' ' run "$CHECK" --container c1
  [ "$status" -eq 2 ]
}

@test "bad arguments are rejected" {
  run "$CHECK" --nope
  [ "$status" -eq 2 ]
  run "$CHECK" --container
  [ "$status" -eq 2 ]
}

@test "an unreadable list file or an unsafe entry stops the sanitiser from building SQL" {
  # shellcheck source=scripts/sanitise/lib.sh
  source "$SRC_ROOT/scripts/sanitise/lib.sh"
  printf "ok_name\nbad'; DROP TABLE x; --\n" >"$BATS_TEST_TMPDIR/list.txt"
  run san_entries "$BATS_TEST_TMPDIR/list.txt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid entry"* ]]
}
