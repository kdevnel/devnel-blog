#!/usr/bin/env bash
# Shared by scripts/pull-db.sh and scripts/check-sanitised.sh. Source this file; don't run it.
#
# The sanitisation list lives once, in the *.txt files next to this file. This library turns it
# into the SQL that sanitises a database and into the queries that check the result, so the two
# can't drift apart.
# shellcheck shell=bash

SAN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAN_PREFIX="wp_"
# The database inside the throwaway container.
SAN_DB="wordpress"

# Regular expressions (ICU, as used by MySQL 8). No backslashes and no single quotes, so they can
# sit inside SQL string literals unchanged.
# An email-shaped string that is not an @example.test address. The "@" may also be URL-encoded
# (%40) or an HTML entity (&#64; or &#x40;), as in a URL or in markup.
SAN_EMAIL_RE='[A-Za-z0-9._%+-]+(@|%40|&#0*64;|&#x0*40;)(?!example[.]test(?![A-Za-z0-9-])(?![.][A-Za-z0-9]))[A-Za-z0-9-]+([.][A-Za-z0-9-]+)*[.][A-Za-z]{2,}'
# An IPv4 address other than 127.0.0.1.
SAN_IPV4_RE='(?<![0-9])(?!127[.]0[.]0[.]1(?![0-9]))(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])([.](25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}(?![0-9])'
# An IPv6 address, full or compressed.
SAN_IPV6_RE='(?<![0-9a-f:])(([0-9a-f]{1,4}:){7}[0-9a-f]{1,4}|([0-9a-f]{1,4}:){1,6}(:[0-9a-f]{1,4}){1,6}|([0-9a-f]{1,4}:){1,7}:|:(:[0-9a-f]{1,4}){1,7})(?![0-9a-f:])'

# Conditions for the three patterns. The cheap LIKE runs first so the (slow) regular expression only
# sees values that could match.
san_email_cond() { printf "((%s LIKE '%%@%%' OR %s LIKE '%%!%%40%%' ESCAPE '!' OR %s LIKE '%%&#%%') AND %s REGEXP '%s')" "$1" "$1" "$1" "$1" "$SAN_EMAIL_RE"; }
san_ipv4_cond() { printf "(%s LIKE '%%.%%.%%.%%' AND %s REGEXP '%s')" "$1" "$1" "$SAN_IPV4_RE"; }
san_ipv6_cond() { printf "(%s LIKE '%%:%%:%%' AND %s REGEXP '%s')" "$1" "$1" "$SAN_IPV6_RE"; }

san_err() { printf 'error: %s\n' "$*" >&2; }

# san_entries <file>: the entries of a list file, without comments and blank lines. Entries are
# restricted to a safe alphabet because they are placed into SQL.
san_entries() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" || "$line" == "#"* ]]; then continue; fi
    if ! [[ "$line" =~ ^[A-Za-z0-9_%!-]+$ ]]; then
      san_err "invalid entry in $1"
      return 1
    fi
    printf '%s\n' "$line"
  done <"$1"
}

# san_cond <column> <entry>: one SQL condition. An entry with % or ! is a LIKE pattern ("!" escapes);
# anything else is an exact match.
san_cond() {
  if [[ "$2" == *"%"* || "$2" == *"!"* ]]; then
    printf "%s LIKE '%s' ESCAPE '!'" "$1" "$2"
  else
    printf "%s = '%s'" "$1" "$2"
  fi
}

# san_cond_all <column> <file>: (cond OR cond ...) for every entry in the file.
san_cond_all() {
  local entry out="" sep=""
  while IFS= read -r entry; do
    out="$out$sep$(san_cond "$1" "$entry")"
    sep=" OR "
  done < <(san_entries "$2")
  [[ -n "$out" ]] || return 1
  printf '(%s)' "$out"
}

# san_sanitise_sql: the static part of the sanitising SQL (everything except TRUNCATE, whose table
# list depends on the database; see san_sanitise).
san_sanitise_sql() {
  local p="$SAN_PREFIX" um opt
  um="$(san_cond_all meta_key "$SAN_DIR/usermeta-delete.txt")"
  opt="$(san_cond_all option_name "$SAN_DIR/options-delete.txt")"
  local types
  types="$(san_cond_all p.post_type "$SAN_DIR/posts-delete-types.txt")"
  printf '%s\n' '-- devnel-sanitise'
  # Cached third-party content (remote ActivityPub actors, Friends feed items): removed with
  # everything that hangs off it, then the posts themselves.
  printf '%s\n' "DELETE cm FROM \`${p}commentmeta\` cm JOIN \`${p}comments\` c ON c.comment_ID = cm.comment_id JOIN \`${p}posts\` p ON p.ID = c.comment_post_ID WHERE $types;"
  printf '%s\n' "DELETE c FROM \`${p}comments\` c JOIN \`${p}posts\` p ON p.ID = c.comment_post_ID WHERE $types;"
  printf '%s\n' "DELETE pm FROM \`${p}postmeta\` pm JOIN \`${p}posts\` p ON p.ID = pm.post_id WHERE $types;"
  printf '%s\n' "DELETE tr FROM \`${p}term_relationships\` tr JOIN \`${p}posts\` p ON p.ID = tr.object_id WHERE $types;"
  printf '%s\n' "DELETE p FROM \`${p}posts\` p WHERE $types;"
  # Contact-form and payment-button recipients.
  printf '%s\n' "DELETE FROM \`${p}postmeta\` WHERE $(san_cond_all meta_key "$SAN_DIR/postmeta-delete.txt");"
  # Any other email address in a post's text (the author's public contact address, examples in
  # revisions) is replaced, not kept: the local copy has no use for real addresses.
  local col
  for col in post_title post_excerpt post_content; do
    printf '%s\n' "UPDATE \`${p}posts\` SET $col = REGEXP_REPLACE($col, '$SAN_EMAIL_RE', 'redacted@example.test') WHERE $(san_email_cond "$col");"
  done
  # Users: emails anonymised, passwords replaced by random hashes, activation keys emptied.
  # user_url, user_login and display names are public and stay.
  printf '%s\n' "UPDATE \`${p}users\` SET user_email = CONCAT('user', ID, '@example.test'), user_pass = CONCAT('\$P\$B', SUBSTRING(SHA2(CONCAT(UUID(), RAND(), ID), 256), 1, 30)), user_activation_key = '';"
  printf '%s\n' "DELETE FROM \`${p}usermeta\` WHERE $um OR meta_value LIKE '%-----BEGIN%';"
  printf '%s\n' "UPDATE \`${p}usermeta\` SET meta_value = CONCAT('meta', umeta_id, '@example.test') WHERE $(san_email_cond meta_value);"
  # Comments: emails, IPs and user agents.
  printf '%s\n' "UPDATE \`${p}comments\` SET comment_author_email = CONCAT('commenter', comment_ID, '@example.test'), comment_author_IP = '127.0.0.1', comment_agent = '';"
  printf '%s\n' "DELETE FROM \`${p}commentmeta\` WHERE $(san_email_cond meta_value) OR $(san_ipv4_cond meta_value) OR $(san_ipv6_cond meta_value);"
  # Options: secrets, keys, salts, transients, and any stored PEM block.
  printf '%s\n' "DELETE FROM \`${p}options\` WHERE $opt OR option_value LIKE '%-----BEGIN%';"
  printf '%s\n' "UPDATE \`${p}options\` SET option_value = 'admin@example.test' WHERE option_name IN ('admin_email', 'new_admin_email');"
}

# san_run <target>: run the SQL on stdin against a target and print the rows (tab-separated, no
# header). A target is "container:<name>" (the throwaway MySQL container) or "wpenv".
san_run() {
  case "$1" in
    container:*)
      # MySQL aborts a regular expression that takes too long; the data here is checked in full.
      docker exec -i "${1#container:}" mysql -uroot --batch --skip-column-names \
        --default-character-set=utf8mb4 --init-command='SET GLOBAL regexp_time_limit = 0' "$SAN_DB"
      ;;
    wpenv)
      # shellcheck disable=SC2086 # WP_ENV is a command prefix such as "npx wp-env"
      # wp-env adds blank lines to stdout; drop them so "no rows" is an empty string.
      ${WP_ENV:-npx wp-env} run cli wp db query --skip-column-names | sed '/^[[:space:]]*$/d'
      ;;
    *)
      san_err "unknown target: $1"
      return 1
      ;;
  esac
}

# san_tables_like <target> <list file>: the existing tables that match the list, one per line.
san_tables_like() {
  local cond
  cond="$(san_cond_all table_name "$2")"
  san_run "$1" <<SQL
SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND $cond ORDER BY table_name;
SQL
}

# san_present_options <target>: the names of the listed options that exist (names only).
san_present_options() {
  {
    printf '%s\n' '-- devnel-present-options'
    printf '%s\n' "SELECT option_name FROM \`${SAN_PREFIX}options\` WHERE $(san_cond_all option_name "$SAN_DIR/options-delete.txt") ORDER BY option_name;"
  } | san_run "$1"
}

# san_delete_options <target>: delete the options on the list (not the rest of the sanitising).
san_delete_options() {
  {
    printf '%s\n' '-- devnel-sanitise-options'
    printf '%s\n' "DELETE FROM \`${SAN_PREFIX}options\` WHERE $(san_cond_all option_name "$SAN_DIR/options-delete.txt");"
  } | san_run "$1"
}

# san_sanitise <target>: sanitise the database behind a target.
san_sanitise() {
  local target="$1" tables t sql
  sql="$(san_sanitise_sql)"
  printf '%s\n' "$sql" | san_run "$target" || return 1
  tables="$(san_tables_like "$target" "$SAN_DIR/truncate-tables.txt")" || return 1
  if [[ -n "$tables" ]]; then
    {
      printf '%s\n' '-- devnel-sanitise-truncate' 'SET FOREIGN_KEY_CHECKS = 0;'
      # shellcheck disable=SC2016 # the backticks are SQL
      while IFS= read -r t; do printf 'TRUNCATE TABLE `%s`;\n' "$t"; done <<<"$tables"
    } | san_run "$target" || return 1
  fi
}
