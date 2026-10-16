#!/usr/bin/env bash
# Check that a database holds no PII or secrets. Fails (exit 1) on any of:
#   - an email-shaped string that is not an @example.test address, in any text column
#   - an IPv4/IPv6 address in the comments or commentmeta tables
#   - a "-----BEGIN" (PEM) block in any text column
#   - an option, usermeta key, postmeta key or post type from the sanitisation lists
#     (scripts/sanitise/*.txt)
#   - a non-empty table from scripts/sanitise/truncate-tables.txt
# It prints table and column names (and list entries), never the matched values.
#
# Usage: scripts/check-sanitised.sh [--wp-env | --container <name>]
#   --wp-env           (default) the wp-env development database
#   --container <name> the throwaway MySQL container that pull-db.sh sanitises in
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/sanitise/lib.sh
source "$root/scripts/sanitise/lib.sh"

target="wpenv"
case "${1:-}" in
  "" | --wp-env) ;;
  --container)
    [[ -n "${2:-}" ]] || {
      san_err "--container needs a name"
      exit 2
    }
    target="container:$2"
    ;;
  *)
    san_err "usage: check-sanitised.sh [--wp-env | --container <name>]"
    exit 2
    ;;
esac

p="$SAN_PREFIX"
text_types="'char','varchar','tinytext','text','mediumtext','longtext'"

cols="$(san_run "$target" <<SQL
SELECT table_name, column_name FROM information_schema.columns
WHERE table_schema = DATABASE() AND data_type IN ($text_types)
ORDER BY table_name, column_name;
SQL
)" || {
  san_err "could not read the database schema (is the target running?)"
  exit 2
}

# Guard against checking an empty or wrong database, which would trivially pass.
if ! grep -qx "${p}options"$'\t'"option_name" <<<"$cols"; then
  san_err "no ${p}options table found: is the database imported?"
  exit 2
fi

has_col() { grep -qx "$1"$'\t'"$2" <<<"$cols"; }

queries=""
add() { queries="$queries${queries:+ UNION ALL }($1)"; }

# select_where <label> <table> <where>: a probe that returns the label if any row matches.
select_where() { add "SELECT '$1' FROM \`$2\` WHERE $3 LIMIT 1"; }

while IFS=$'\t' read -r table column; do
  [[ -n "$table" ]] || continue
  select_where "email $table.$column" "$table" "$(san_email_cond "\`$column\`")"
  select_where "pem $table.$column" "$table" "\`$column\` LIKE '%-----BEGIN%'"
  if [[ "$table" == "${p}comments" || "$table" == "${p}commentmeta" ]]; then
    select_where "ip $table.$column" "$table" "$(san_ipv4_cond "\`$column\`")"
  fi
done <<<"$cols"

for spec in "comments comment_author_IP" "commentmeta meta_value"; do
  read -r short column <<<"$spec"
  if has_col "${p}$short" "$column"; then
    select_where "ip ${p}$short.$column" "${p}$short" "$(san_ipv6_cond "\`$column\`")"
  fi
done

while IFS= read -r entry; do
  select_where "option $entry" "${p}options" "$(san_cond option_name "$entry")"
done < <(san_entries "$SAN_DIR/options-delete.txt")

if has_col "${p}usermeta" meta_key; then
  while IFS= read -r entry; do
    select_where "usermeta $entry" "${p}usermeta" "$(san_cond meta_key "$entry")"
  done < <(san_entries "$SAN_DIR/usermeta-delete.txt")
fi

if has_col "${p}posts" post_type; then
  while IFS= read -r entry; do
    select_where "posttype $entry" "${p}posts" "$(san_cond post_type "$entry")"
  done < <(san_entries "$SAN_DIR/posts-delete-types.txt")
fi

if has_col "${p}postmeta" meta_key; then
  while IFS= read -r entry; do
    select_where "postmeta $entry" "${p}postmeta" "$(san_cond meta_key "$entry")"
  done < <(san_entries "$SAN_DIR/postmeta-delete.txt")
fi

tables="$(san_tables_like "$target" "$SAN_DIR/truncate-tables.txt")" || {
  san_err "could not list the tables to check"
  exit 2
}
while IFS= read -r table; do
  [[ -n "$table" ]] || continue
  add "SELECT 'nonempty $table' FROM \`$table\` LIMIT 1"
done <<<"$tables"

found="$(printf '%s\n%s;\n' '-- devnel-check' "$queries" | san_run "$target")" || {
  san_err "the check queries failed"
  exit 2
}

if [[ -n "$found" ]]; then
  count="$(printf '%s\n' "$found" | sort -u | wc -l | tr -d ' ')"
  echo "FAIL: the database is not sanitised ($count problem(s)):" >&2
  printf '%s\n' "$found" | sort -u | sed 's/^/  /' >&2
  exit 1
fi
echo "OK: no emails, IPs, PEM blocks, listed options or listed tables left."
