#!/usr/bin/env bats
# The sanitising SQL and check-sanitised.sh against a real MySQL 8.4 server in a throwaway
# container, loaded with made-up data (tests/shell/fixtures/dirty.sql). This is what proves the
# detection queries and the sanitiser actually work; the stubbed tests only cover the wiring.
# Skipped when docker isn't available. Uses the real docker (no stubs on PATH).

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
CHECK="$REPO_ROOT/scripts/check-sanitised.sh"
FIXTURE="$BATS_TEST_DIRNAME/fixtures/dirty.sql"

setup_file() {
  if ! docker info >/dev/null 2>&1; then return 0; fi
  CONTAINER="devnel-sanitise-test-$$-$RANDOM"
  export CONTAINER
  docker run -d --name "$CONTAINER" --network none --tmpfs /var/lib/mysql:rw,mode=1777 \
    -e MYSQL_ALLOW_EMPTY_PASSWORD=1 -e MYSQL_DATABASE=wordpress \
    mysql:8.4 --skip-log-bin >/dev/null
  local i
  for ((i = 0; i < 90; i++)); do
    if docker exec "$CONTAINER" mysqladmin ping -h 127.0.0.1 --protocol=tcp -uroot --silent >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "MySQL container did not become ready" >&2
  return 1
}

teardown_file() {
  if [[ -n "${CONTAINER:-}" ]]; then docker rm -f -v "$CONTAINER" >/dev/null 2>&1 || true; fi
}

setup() {
  if ! docker info >/dev/null 2>&1; then skip "docker is not available"; fi
  # A fresh copy of the dirty fixture for every test.
  sql "DROP DATABASE IF EXISTS wordpress; CREATE DATABASE wordpress;"
  docker exec -i "$CONTAINER" mysql -uroot --default-character-set=utf8mb4 wordpress <"$FIXTURE"
}

# sql <statement>: run SQL in the container.
sql() { docker exec "$CONTAINER" mysql -uroot --batch --skip-column-names wordpress -e "$1"; }

sanitise() {
  # shellcheck source=scripts/sanitise/lib.sh
  source "$REPO_ROOT/scripts/sanitise/lib.sh"
  san_sanitise "container:$CONTAINER"
}

run_check() { run "$CHECK" --container "$CONTAINER"; }

@test "the dirty fixture fails the check in every violation class" {
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"  email wp_users.user_email"* ]]
  [[ "$output" == *"  email wp_comments.comment_author_email"* ]]
  [[ "$output" == *"  email wp_usermeta.meta_value"* ]]
  [[ "$output" == *"  email wp_options.option_value"* ]]
  [[ "$output" == *"  ip wp_comments.comment_author_IP"* ]]
  [[ "$output" == *"  ip wp_commentmeta.meta_value"* ]]
  [[ "$output" == *"  pem wp_options.option_value"* ]]
  [[ "$output" == *"  pem wp_usermeta.meta_value"* ]]
  [[ "$output" == *"  option mailserver_pass"* ]]
  [[ "$output" == *"  option updraft_s3"* ]]
  [[ "$output" == *"  usermeta session_tokens"* ]]
  [[ "$output" == *"  nonempty wp_post_smtp_logs"* ]]
  [[ "$output" == *"  nonempty wp_zbs_contacts"* ]]
}

@test "the check prints table and column names, never the matched values" {
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" != *"corp.example.org"* ]]
  [[ "$output" != *"mail.invalid"* ]]
  [[ "$output" != *"203.0.113"* ]]
  [[ "$output" != *"2001:db8"* ]]
  [[ "$output" != *"fake"* ]]
}

@test "sanitising makes the check pass" {
  sanitise
  run_check
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == OK* ]]
}

@test "sanitising: users get userN@example.test, a new password hash, no activation key; user_url is kept" {
  sanitise
  [ "$(sql "SELECT user_email FROM wp_users ORDER BY ID")" = $'user1@example.test\nuser2@example.test' ]
  [ "$(sql "SELECT COUNT(*) FROM wp_users WHERE user_pass LIKE 'fake-hash%' OR user_activation_key <> ''")" = 0 ]
  [ "$(sql "SELECT COUNT(DISTINCT user_pass) FROM wp_users")" = 2 ]
  [ "$(sql "SELECT user_url FROM wp_users WHERE user_login = 'alice'")" = "https://alice.example.org" ]
}

@test "sanitising: usermeta secrets deleted, emails anonymised, harmless meta kept" {
  sanitise
  [ "$(sql "SELECT COUNT(*) FROM wp_usermeta WHERE meta_key IN ('session_tokens','magic_sig_private_key','magic_sig_public_key','jetpack_account_protection_recent_password_hashes','_application_passwords','my_private_note','service_API_TOKEN','x_secret_y','keypair')")" = 0 ]
  [ "$(sql "SELECT meta_value FROM wp_usermeta WHERE meta_key = 'description'")" = "meta2@example.test" ]
  [ "$(sql "SELECT meta_value FROM wp_usermeta WHERE meta_key = 'locale'")" = "en_GB" ]
  [ "$(sql "SELECT meta_value FROM wp_usermeta WHERE meta_key = 'nickname'")" = "alice" ]
}

@test "sanitising: comments get commenterN@example.test, 127.0.0.1, no agent; commentmeta with emails or IPs is cleared" {
  sanitise
  [ "$(sql "SELECT comment_author_email FROM wp_comments ORDER BY comment_ID")" = $'commenter1@example.test\ncommenter2@example.test' ]
  [ "$(sql "SELECT DISTINCT comment_author_IP FROM wp_comments")" = "127.0.0.1" ]
  [ "$(sql "SELECT COUNT(*) FROM wp_comments WHERE comment_agent <> ''")" = 0 ]
  [ "$(sql "SELECT GROUP_CONCAT(meta_key) FROM wp_commentmeta")" = "akismet_result" ]
  # comment text and author URLs are public and stay
  [ "$(sql "SELECT comment_content FROM wp_comments WHERE comment_ID = 1")" = "Nice post, version 2.0 is out" ]
  [ "$(sql "SELECT comment_author_url FROM wp_comments WHERE comment_ID = 1")" = "https://carol.example.net" ]
}

@test "sanitising: listed tables are emptied; the redirection items and groups survive" {
  sanitise
  for t in wp_post_smtp_logs wp_post_smtp_logmeta wp_redirection_404 wp_redirection_logs wp_jetpack_waf_blocklog wp_zbs_contacts wp_zbs_invoices; do
    [ "$(sql "SELECT COUNT(*) FROM $t")" = 0 ]
  done
  [ "$(sql "SELECT COUNT(*) FROM wp_redirection_items")" = 1 ]
  [ "$(sql "SELECT COUNT(*) FROM wp_redirection_groups")" = 1 ]
}

@test "sanitising: secret options, keys, salts, transients and PEM options are deleted; ordinary options kept; admin_email replaced" {
  sanitise
  [ "$(sql "SELECT GROUP_CONCAT(option_name ORDER BY option_name) FROM wp_options")" = "admin_email,blogdescription,blogname,home,new_admin_email,siteurl,updraft_interval" ]
  [ "$(sql "SELECT option_value FROM wp_options WHERE option_name = 'admin_email'")" = "admin@example.test" ]
  [ "$(sql "SELECT option_value FROM wp_options WHERE option_name = 'siteurl'")" = "https://devnel.blog" ]
}

@test "sanitising leaves posts and pages alone" {
  sanitise
  [ "$(sql "SELECT COUNT(*) FROM wp_posts")" = 2 ]
  [ "$(sql "SELECT post_content FROM wp_posts WHERE ID = 1")" = '<!-- wp:paragraph --><p>Hello there, 3.14 is pi</p><!-- /wp:paragraph -->' ]
}

# --- one violation at a time, starting from a sanitised database --------------------------------

# expect_only <label>: the check fails and reports exactly that one problem.
expect_only() {
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"(1 problem(s))"* ]]
  [[ "$output" == *"  $1"* ]]
}

@test "detects an email outside example.test in a post" {
  sanitise
  sql "UPDATE wp_posts SET post_content = 'mail me: someone@gmail.com' WHERE ID = 1"
  expect_only "email wp_posts.post_content"
}

@test "an email-shaped value on a look-alike domain of example.test is still caught" {
  sanitise
  sql "UPDATE wp_posts SET post_content = 'x@example.test.evil.org' WHERE ID = 1"
  expect_only "email wp_posts.post_content"
}

@test "example.test addresses are allowed, including in prose" {
  sanitise
  sql "UPDATE wp_posts SET post_content = 'write to a@example.test.' WHERE ID = 1"
  run_check
  [ "$status" -eq 0 ]
}

@test "detects an IPv4 address in comment text" {
  sanitise
  sql "UPDATE wp_comments SET comment_content = 'seen from 198.51.100.23' WHERE comment_ID = 1"
  expect_only "ip wp_comments.comment_content"
}

@test "detects an IPv6 address in comment_author_IP, and allows 127.0.0.1" {
  sanitise
  run_check
  [ "$status" -eq 0 ]
  sql "UPDATE wp_comments SET comment_author_IP = '2001:db8:85a3::8a2e:370:7334' WHERE comment_ID = 1"
  expect_only "ip wp_comments.comment_author_IP"
}

@test "detects an IPv4 address in commentmeta" {
  sanitise
  sql "INSERT INTO wp_commentmeta (comment_id, meta_key, meta_value) VALUES (1, 'x', '192.0.2.44')"
  expect_only "ip wp_commentmeta.meta_value"
}

@test "an IP-looking version string with fewer than four parts is not an IP" {
  sanitise
  sql "UPDATE wp_comments SET comment_content = 'works on 1.2.3 and 10.5' WHERE comment_ID = 1"
  run_check
  [ "$status" -eq 0 ]
}

@test "detects a PEM block in options" {
  sanitise
  sql "INSERT INTO wp_options (option_name, option_value) VALUES ('harmless_name', CONCAT('-----BE', 'GIN X-----'))"
  expect_only "pem wp_options.option_value"
}

@test "detects a PEM block in usermeta" {
  sanitise
  sql "INSERT INTO wp_usermeta (user_id, meta_key, meta_value) VALUES (1, 'harmless_name', CONCAT('-----BE', 'GIN X-----'))"
  expect_only "pem wp_usermeta.meta_value"
}

@test "detects a listed option name that is still present, exact and pattern" {
  sanitise
  sql "INSERT INTO wp_options (option_name, option_value) VALUES ('friends_codeword', 'x')"
  expect_only "option friends_codeword"
  sql "DELETE FROM wp_options WHERE option_name = 'friends_codeword'; INSERT INTO wp_options (option_name, option_value) VALUES ('mwp_anything', 'x')"
  expect_only "option mwp!_%"
}

@test "an option that only resembles a listed name is not flagged" {
  sanitise
  sql "INSERT INTO wp_options (option_name, option_value) VALUES ('mwpx', 'x'), ('auth_keys', 'x'), ('my_transient', 'x')"
  run_check
  [ "$status" -eq 0 ]
}

@test "detects a listed usermeta key that is still present" {
  sanitise
  sql "INSERT INTO wp_usermeta (user_id, meta_key, meta_value) VALUES (1, 'session_tokens', 'x')"
  expect_only "usermeta session_tokens"
}

@test "detects a non-empty truncated table, including a wp_zbs_ table created later" {
  sanitise
  sql "INSERT INTO wp_post_smtp_logs VALUES (9, 'x')"
  expect_only "nonempty wp_post_smtp_logs"
  sql "DELETE FROM wp_post_smtp_logs; CREATE TABLE wp_zbs_new_thing (id int); INSERT INTO wp_zbs_new_thing VALUES (1)"
  expect_only "nonempty wp_zbs_new_thing"
}

@test "an empty database is refused rather than passing" {
  sql "DROP DATABASE wordpress; CREATE DATABASE wordpress"
  run_check
  [ "$status" -eq 2 ]
  [[ "$output" == *"is the database imported"* ]]
}

@test "sanitising twice is harmless" {
  sanitise
  sanitise
  run_check
  [ "$status" -eq 0 ]
}
