#!/usr/bin/env bats
# A tripwire for the local-environment scripts: it catches the obvious and the accidental, and
# code review stays the control that stops a determined change.
#
# Every line of every file under scripts/ and tools/ (scripts, data lists and all), of package.json
# and of .wp-env.json is first normalised (quotes and backslashes removed, so s''sh, "s"sh, s\sh and
# tri""ton read as ssh and triton). If it then mentions ssh, rsync, scp, sftp, $PROD_HOST, the
# production host, eval, bash -c or sh -c, runs a variable or exec as a command, or sources or runs a
# file that isn't one of the scanned scripts, the ORIGINAL line must match one of a short list of
# exact forms (below). Anything else fails, until a human adds it here on purpose.
#
# Allowed remote commands (ssh joins its arguments into ONE remote command, so the form allows
# exactly one quoted argument):
#   wp db export - --single-transaction     (via PROD_EXPORT_CMD; stdout only)
#   wp core version
#   wp plugin list --skip-update-check --skip-plugins --skip-themes --fields=name,version,status --format=json
#     (without --skip-update-check, wp plugin list refreshes the update_plugins transient: a write)
# Allowed rsync: production is the source, the last argument is local, no --remove-source-files.
#
# What it cannot catch: strings assembled at run time (printf, base64, variables concatenated
# piece by piece), code in another language (node, python, awk) that opens a connection itself, and
# anything outside the scanned files. scripts/backup/ is not scanned: it runs on Triton itself, and
# a test below proves it contains no ssh, rsync, scp or sftp at all.

SRC_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

ALLOWED_REMOTE=(
  "cd ~/devnel.blog/public && wp core version"
  "cd ~/devnel.blog/public && wp plugin list --skip-update-check --skip-plugins --skip-themes --fields=name,version,status --format=json"
)

# Lines that mention the watched words for harmless reasons, or run a variable on purpose.
# Each must match exactly.
ALLOWED_LINES=(
  'PROD_HOST="${DEVNEL_PROD_HOST:-triton.devnel.com}"'
  "PROD_EXPORT_CMD='cd ~/devnel.blog/public && wp db export - --single-transaction'"
  'command -v ssh >/dev/null 2>&1 || die "ssh not found"'
  'command -v rsync >/dev/null 2>&1 || die "rsync not found"'
  'echo "[pull-uploads] rsync $PROD_HOST:$REMOTE_UPLOADS -> ${dest#"$root_real"/}" >&2'
  'exec npx wp-env start "$@"'
  '$WP_ENV run cli wp "$@"'
  "\${WP_ENV:-npx wp-env} run cli wp db query --skip-column-names | sed '/^[[:space:]]*\$/d'"
  '"$CHECK_SCRIPT" --container "$container" || die "the sanitised database failed the check; nothing was imported"'
  '"$IMAGE" --skip-log-bin --max-allowed-packet=256M --innodb-flush-log-at-trx-commit=2 \'
  '"$CHECK_SCRIPT" --wp-env || die "wp-env failed the sanitisation check"'
)

# Per-file exceptions, as "<file name>|<exact line>" (data lists that name a plugin option).
ALLOWED_FILE_LINES=(
  "options-delete.txt|updraft_sftp"
)

EXPORT_LINE='ssh "$PROD_HOST" "$PROD_EXPORT_CMD" |'
WATCHED='ssh|rsync|scp|sftp|PROD_HOST|PROD_EXPORT_CMD|triton|eval|bash -c|sh -c'
EXEC_RE='(^|[;&|(])[[:space:]]*exec[[:space:]]'
# A variable used as the command: at the start, or after ; & && || | or $(
VAR_CMD_RE='(^|[;&|]|\$\()[[:space:]]*\$\{?[A-Za-z_][^[:space:]]*[[:space:]]+[^]|=!<>&[:space:]]'
# source, . , bash or sh followed by a file (group 4 or 6 is the file)
RUN_FILE_RE='(^|[^A-Za-z0-9_./-])(source|bash|sh)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*([^[:space:];&|)]+)|(^|[;&|(])[[:space:]]*\.[[:space:]]+([^[:space:];&|)]+)'
SSH_RE='^([A-Za-z_][A-Za-z_0-9]*="\$\()?ssh "\$PROD_HOST" '"'"'([^'"'"']*)'"'"'(\)")?( \|\| die "[^"$`]*")?( \|\|)?$'
RSYNC_RE='^rsync( -a| --delete| --delete-excluded| --exclude-from="\$EXCLUDE_FILE")+ "\$PROD_HOST:\$REMOTE_UPLOADS" "\$dest/"( \|\| die "[^"$`]*")?$'

# is_scanned_script <path as written>: the target of a source/bash/sh is one of the scanned scripts
# (not a data list), once $root/ is dropped.
is_scanned_script() {
  local t="$1"
  t="${t//\"/}"
  t="${t//\$root\//}"
  t="${t//\$\{root\}\//}"
  t="${t#./}"
  t="${t%,}"
  [[ "$t" == *'$'* || "$t" == /* || "$t" == *.txt ]] && return 1
  files_to_check | sed "s|^$SRC_ROOT/||" | grep -qxF "$t"
}

# watched <normalised line>: the line mentions something this test watches.
watched() {
  local r=1
  shopt -s nocasematch
  if [[ "$1" =~ $WATCHED || "$1" =~ $EXEC_RE || "$1" =~ $VAR_CMD_RE ]]; then r=0; fi
  shopt -u nocasematch
  return $r
}

# line_ok <trimmed line> [file name]: succeed if the line is allowed.
line_ok() {
  local line="$1" fname="${2:-}" norm allowed rest target="" runs=0
  norm="${line//\'/}"
  norm="${norm//\"/}"
  norm="${norm//\\/}"
  if [[ "$norm" =~ $RUN_FILE_RE ]]; then
    runs=1
    target="${BASH_REMATCH[4]:-${BASH_REMATCH[6]:-}}"
  fi
  if ! watched "$norm"; then
    # nothing watched; a source/bash/sh must still name a scanned script
    if [[ "$runs" == 1 ]] && ! is_scanned_script "$target"; then
      :
    else
      return 0
    fi
  fi
  for allowed in "${ALLOWED_LINES[@]}"; do
    [[ "$line" == "$allowed" ]] && return 0
  done
  for allowed in "${ALLOWED_FILE_LINES[@]}"; do
    [[ "$fname|$line" == "$allowed" ]] && return 0
  done
  [[ "$line" == "$EXPORT_LINE" ]] && return 0
  if [[ "$line" =~ $SSH_RE ]]; then
    # the command substitution must be opened and closed together
    if [[ -n "${BASH_REMATCH[1]}" && -z "${BASH_REMATCH[3]}" ]] || [[ -z "${BASH_REMATCH[1]}" && -n "${BASH_REMATCH[3]}" ]]; then
      return 1
    fi
    rest="${BASH_REMATCH[2]}"
    for allowed in "${ALLOWED_REMOTE[@]}"; do
      [[ "$rest" == "$allowed" ]] && return 0
    done
    return 1
  fi
  [[ "$line" =~ $RSYNC_RE ]] && return 0
  return 1
}

# check_script <file>: print the first offending line and return 1 if the file could write to production.
check_script() {
  local file="$1" line trimmed fname
  fname="$(basename "$file")"
  # .wp-env.json may not run commands at all (lifecycleScripts), whatever they say
  if [[ "$fname" == .wp-env*.json ]] && grep -q 'lifecycleScripts' "$file"; then
    echo "$file: lifecycleScripts is not allowed"
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    # comment lines don't run
    [[ "$trimmed" == "#"* || -z "$trimmed" ]] && continue
    if ! line_ok "$trimmed" "$fname"; then
      echo "$file: not an allowed read-only form: $trimmed"
      return 1
    fi
  done <"$file"
  return 0
}

# Every tracked script, data list and config that could run something: scripts/** and tools/**
# (all file types, except scripts/backup, see above), package.json and .wp-env.json.
files_to_check() {
  find "$SRC_ROOT/scripts" "$SRC_ROOT/tools" -type f ! -path '*/backup/*' ! -path '*/node_modules/*' | sort
  echo "$SRC_ROOT/package.json"
  echo "$SRC_ROOT/.wp-env.json"
}

@test "every line mentioning ssh, rsync or the production host in scripts/, tools/, package.json and .wp-env.json is an allowed read-only form" {
  count=0
  while IFS= read -r f; do
    run check_script "$f"
    echo "$output"
    [ "$status" -eq 0 ]
    count=$((count + 1))
  done < <(files_to_check)
  [ "$count" -ge 8 ]
}

@test "the new scripts are scanned and really use ssh or rsync (the scan is not vacuous)" {
  list="$(files_to_check)"
  [[ "$list" == *"/scripts/pull-db.sh"* ]]
  [[ "$list" == *"/scripts/sync-env-versions.sh"* ]]
  [[ "$list" == *"/scripts/pull-uploads.sh"* ]]
  [[ "$list" == *"/scripts/sanitise/lib.sh"* ]]
  [[ "$list" == *"/package.json"* && "$list" == *"/.wp-env.json"* ]]
  grep -qxF "$EXPORT_LINE" "$SRC_ROOT/scripts/pull-db.sh"
  grep -q 'ssh "\$PROD_HOST" '"'" "$SRC_ROOT/scripts/sync-env-versions.sh"
  grep -q '^rsync -a --delete' "$SRC_ROOT/scripts/pull-uploads.sh"
}

@test "scripts/backup/ runs on the server and uses no ssh, rsync, scp or sftp at all" {
  ! grep -rEn '(^|[^A-Za-z_-])(ssh|rsync|scp|sftp)([^A-Za-z_-]|$)' "$SRC_ROOT/scripts/backup" | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || false
}

@test "the export command is exactly the read-only one, and used only through PROD_EXPORT_CMD" {
  [ "$(grep -c 'PROD_EXPORT_CMD' "$SRC_ROOT/scripts/pull-db.sh")" -eq 2 ]
  grep -qxF "PROD_EXPORT_CMD='cd ~/devnel.blog/public && wp db export - --single-transaction'" "$SRC_ROOT/scripts/pull-db.sh"
}

# --- self-tests: the checker must reject every one of these -------------------------------------

@test "the check rejects writes, bypasses and indirect invocations (self-test)" {
  bad="$BATS_TEST_TMPDIR/bad.sh"
  cases=(
    "ssh \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp option update siteurl x'"
    "ssh \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp plugin update --all'"
    "ssh \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp plugin list --fields=name,version,status --format=json'"
    "ssh \"\$PROD_HOST\" 'rm -rf ~/devnel.blog/backups'"
    "ssh \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp db reset --yes' || die \"x\""
    "out=\"\$(ssh \"\$PROD_HOST\" 'rm -rf ~/devnel.blog/public')\" || die \"could not\""
    "ssh \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp core version' '; rm -rf ~/x'"
    "ssh \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp core version'; rm -rf ~/x"
    "ssh \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp core version' \\"
    "eval \"ssh \$PROD_HOST 'wp option update x y'\""
    "s''sh \"\$PROD_HOST\" 'rm -rf /'"
    "\"s\"sh \"\$PROD_HOST\" 'rm -rf /'"
    "s\\sh \"\$PROD_HOST\" 'rm -rf /'"
    "H=tri\"\"ton.devnel.com"
    "printf x | \$x \"\$H\""
    "printf x | \"\$x\" \"\$H\""
    "printf x | xargs -I{} s''sh {} 'rm -rf /'"
    "export DOCKER_HOST=s''sh://triton.devnel.com"
    "r=(s''sh \"\$H\" 'rm -rf /')"
    "source \"\$root/scripts/sanitise/options-delete.txt\""
    "source /tmp/evil.sh"
    "bash /tmp/evil.sh"
    ". ./evil.sh"
    "sh -c 'echo hi'"
    "ssh \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp plugin list --skip-update-check --fields=name,version,status --format=json'"
    "cmd=\"ssh \$PROD_HOST 'rm -rf /'\"; \$cmd"
    "SSH=ssh; \$SSH \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp core version'"
    "\$SSH \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp core version'"
    "\"\$remote\" 'wp option update x y'"
    "\"ssh\" \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp core version'"
    "command ssh \"\$PROD_HOST\" 'rm -rf /'"
    "exec ssh \"\$PROD_HOST\" 'rm -rf /'"
    "exec \$tool"
    "bash -c 'ssh host \"rm -rf /\"'"
    "ssh triton.devnel.com 'cd ~/devnel.blog/public && wp core version'"
    "ssh \"\$PROD_HOST\" \"\$SOMETHING_ELSE\""
    "ssh -o BatchMode=yes \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp core version'"
    "scp dump.sql triton.devnel.com:/tmp/"
    "sftp triton.devnel.com"
    "rsync -a \"\$dest/\" \"\$PROD_HOST:\$REMOTE_UPLOADS\" || die \"x\""
    "rsync -a --delete \"\$dest/\" \"\$PROD_HOST:\$REMOTE_UPLOADS\""
    "rsync -a --remove-source-files \"\$PROD_HOST:\$REMOTE_UPLOADS\" \"\$dest/\""
    "rsync -a --delete \"\$PROD_HOST:\$REMOTE_UPLOADS\" \"\$PROD_HOST:/tmp/x\""
    "rsync -a -e 'ssh -i key' \"\$PROD_HOST:\$REMOTE_UPLOADS\" \"\$dest/\""
    "PROD_EXPORT_CMD='cd ~/devnel.blog/public && wp db reset --yes'"
    "PROD_HOST=evil.example.test"
    "echo \"\$PROD_HOST\" > /dev/null"
  )
  for c in "${cases[@]}"; do
    printf '%s\n' "$c" >"$bad"
    run check_script "$bad"
    if [ "$status" -eq 0 ]; then
      echo "not caught: $c"
      return 1
    fi
  done
}

@test "data lists are scanned too; the one real exception is per file (self-test)" {
  d="$BATS_TEST_TMPDIR/lists"
  mkdir -p "$d"
  printf 'updraft_sftp\n' >"$d/options-delete.txt"
  run check_script "$d/options-delete.txt"
  [ "$status" -eq 0 ]
  # the same line in any other file is rejected
  printf 'updraft_sftp\n' >"$d/other.txt"
  run check_script "$d/other.txt"
  [ "$status" -ne 0 ]
  printf 'ssh triton.devnel.com\n' >"$d/options-delete.txt"
  run check_script "$d/options-delete.txt"
  [ "$status" -ne 0 ]
}

@test ".wp-env.json may not have lifecycleScripts or commands that touch production (self-test)" {
  d="$BATS_TEST_TMPDIR/cfg"
  mkdir -p "$d"
  printf '{ "lifecycleScripts": { "afterStart": "echo hi" } }\n' >"$d/.wp-env.json"
  run check_script "$d/.wp-env.json"
  [ "$status" -ne 0 ]
  printf '{ "afterStart": "ssh host id" }\n' >"$d/.wp-env.override.json"
  run check_script "$d/.wp-env.override.json"
  [ "$status" -ne 0 ]
  run grep -c lifecycleScripts "$SRC_ROOT/.wp-env.json"
  [ "$output" = 0 ]
}

@test "the check accepts the real forms (self-test)" {
  good="$BATS_TEST_TMPDIR/good.sh"
  {
    echo 'PROD_HOST="${DEVNEL_PROD_HOST:-triton.devnel.com}"'
    echo "PROD_EXPORT_CMD='cd ~/devnel.blog/public && wp db export - --single-transaction'"
    echo "$EXPORT_LINE"
    echo "core=\"\$(ssh \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp core version')\" || die \"could not read the core version\""
    echo "p=\"\$(ssh \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp plugin list --skip-update-check --skip-plugins --skip-themes --fields=name,version,status --format=json')\" ||"
    echo '  die "could not read the plugin list"'
    echo 'rsync -a --delete --delete-excluded --exclude-from="$EXCLUDE_FILE" "$PROD_HOST:$REMOTE_UPLOADS" "$dest/"'
    echo '# ssh "$PROD_HOST" '"'rm -rf /'"' in a comment is fine'
    echo 'command -v ssh >/dev/null 2>&1 || die "ssh not found"'
    echo 'docker exec -i "$container" mysql -uroot'
    echo 'source "$root/scripts/sanitise/lib.sh"'
  } >"$good"
  run check_script "$good"
  echo "$output"
  [ "$status" -eq 0 ]
}
