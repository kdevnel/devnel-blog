#!/usr/bin/env bats
# Static guard: nothing the local-environment scripts run on production can write.
#
# Every line, in any file under scripts/ and tools/ (not only *.sh) and in package.json, that
# mentions ssh, rsync, scp, sftp, $PROD_HOST, the production host, eval, bash -c, or runs a variable
# or exec as a command must match one of a short list of exact forms (below). Anything else fails,
# so a new remote command, an indirect or quoted invocation, or a second argument smuggled into the
# remote command is caught until a human adds it here on purpose.
#
# Allowed remote commands (ssh joins its arguments into ONE remote command, so the form allows
# exactly one quoted argument):
#   wp db export - --single-transaction     (via PROD_EXPORT_CMD; stdout only)
#   wp core version
#   wp plugin list --skip-update-check --fields=name,version,status --format=json
#     (without --skip-update-check, wp plugin list refreshes the update_plugins transient: a write)
# Allowed rsync: production is the source, the last argument is local, no --remove-source-files.
#
# Data files (*.txt, such as the sanitisation lists) are not scanned: nothing executes them.
# scripts/backup/ runs on Triton itself and uses no ssh or rsync at all; a test below proves that.

SRC_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

ALLOWED_REMOTE=(
  "cd ~/devnel.blog/public && wp core version"
  "cd ~/devnel.blog/public && wp plugin list --skip-update-check --fields=name,version,status --format=json"
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

EXPORT_LINE='ssh "$PROD_HOST" "$PROD_EXPORT_CMD" |'
WATCHED='ssh|rsync|scp|sftp|PROD_HOST|PROD_EXPORT_CMD|triton|eval|bash -c|sh -c'
EXEC_RE='(^|[;&|(])[[:space:]]*exec[[:space:]]'
VAR_CMD_RE='(^|[;&]|\|\||\$\()[[:space:]]*"?\$\{?[A-Za-z_][^[:space:]]*[[:space:]]+[^]|=!<>&[:space:]]'
SSH_RE='^([A-Za-z_][A-Za-z_0-9]*="\$\()?ssh "\$PROD_HOST" '"'"'([^'"'"']*)'"'"'(\)")?( \|\| die "[^"$`]*")?( \|\|)?$'
RSYNC_RE='^rsync( -a| --delete| --delete-excluded| --exclude-from="\$EXCLUDE_FILE")+ "\$PROD_HOST:\$REMOTE_UPLOADS" "\$dest/"( \|\| die "[^"$`]*")?$'

# line_ok <trimmed line>: succeed if the line is allowed.
line_ok() {
  local line="$1" allowed rest
  shopt -s nocasematch
  if ! [[ "$line" =~ $WATCHED || "$line" =~ $EXEC_RE || "$line" =~ $VAR_CMD_RE ]]; then
    shopt -u nocasematch
    return 0
  fi
  shopt -u nocasematch
  for allowed in "${ALLOWED_LINES[@]}"; do
    [[ "$line" == "$allowed" ]] && return 0
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
  local file="$1" line trimmed
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ "$trimmed" == "#"* || -z "$trimmed" ]] && continue
    if ! line_ok "$trimmed"; then
      echo "$file: not an allowed read-only form: $trimmed"
      return 1
    fi
  done <"$file"
  return 0
}

# Every script-like tracked file: scripts/** and tools/** (except data lists), plus package.json.
files_to_check() {
  find "$SRC_ROOT/scripts" "$SRC_ROOT/tools" -type f ! -name '*.txt' ! -path '*/backup/*' ! -path '*/node_modules/*' | sort
  echo "$SRC_ROOT/package.json"
}

@test "every line mentioning ssh, rsync or the production host in scripts/, tools/ and package.json is an allowed read-only form" {
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
  [[ "$list" == *"/package.json" ]]
  grep -qxF "$EXPORT_LINE" "$SRC_ROOT/scripts/pull-db.sh"
  grep -q 'ssh "\$PROD_HOST" '"'" "$SRC_ROOT/scripts/sync-env-versions.sh"
  grep -q '^rsync -a --delete' "$SRC_ROOT/scripts/pull-uploads.sh"
}

@test "scripts/backup/ runs on the server and uses no ssh, rsync, scp or sftp at all" {
  ! grep -rEn '(^|[^A-Za-z_-])(ssh|rsync|scp|sftp)([^A-Za-z_-]|$)' "$SRC_ROOT/scripts/backup" | grep -v '^[^:]*:[0-9]*:[[:space:]]*#'
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

@test "the check accepts the real forms (self-test)" {
  good="$BATS_TEST_TMPDIR/good.sh"
  {
    echo 'PROD_HOST="${DEVNEL_PROD_HOST:-triton.devnel.com}"'
    echo "PROD_EXPORT_CMD='cd ~/devnel.blog/public && wp db export - --single-transaction'"
    echo "$EXPORT_LINE"
    echo "core=\"\$(ssh \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp core version')\" || die \"could not read the core version\""
    echo "p=\"\$(ssh \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp plugin list --skip-update-check --fields=name,version,status --format=json')\" ||"
    echo '  die "could not read the plugin list"'
    echo 'rsync -a --delete --delete-excluded --exclude-from="$EXCLUDE_FILE" "$PROD_HOST:$REMOTE_UPLOADS" "$dest/"'
    echo '# ssh "$PROD_HOST" '"'rm -rf /'"' in a comment is fine'
    echo 'command -v ssh >/dev/null 2>&1 || die "ssh not found"'
    echo 'docker exec -i "$container" mysql -uroot'
  } >"$good"
  run check_script "$good"
  echo "$output"
  [ "$status" -eq 0 ]
}
