#!/usr/bin/env bats
# Static guard: nothing the local-environment scripts run on production can write.
# Every ssh call in scripts/ (outside scripts/backup, which runs *on* the server) must be one of:
#   wp db export - --single-transaction     (stdout only)
#   wp core version
#   wp plugin list --fields=name,version,status --format=json
# and the only rsync allowed has production as the *source*, without --remove-source-files.
# A new script that adds another remote command fails here until a human adds it to the allowlist.

SRC_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

ALLOWED_REMOTE=(
  "cd ~/devnel.blog/public && wp db export - --single-transaction"
  "cd ~/devnel.blog/public && wp core version"
  "cd ~/devnel.blog/public && wp plugin list --fields=name,version,status --format=json"
)
EXPORT_CMD_ASSIGNMENT="PROD_EXPORT_CMD='cd ~/devnel.blog/public && wp db export - --single-transaction'"
ALLOWED_RSYNC='rsync -a --delete "$PROD_HOST:$REMOTE_UPLOADS" "$dest/"'

# check_script <file>: print a reason and return 1 if the file could write to production.
check_script() {
  local file="$1" line trimmed remote ok allowed
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ "$trimmed" == "#"* || -z "$trimmed" ]] && continue

    # Other ways to reach or copy to a remote host are never allowed.
    if [[ "$trimmed" =~ (^|[^A-Za-z0-9_-])(scp|sftp|sshfs|ssh-copy-id|ssh-keygen|ssh-add)([^A-Za-z0-9_-]|$) ]]; then
      echo "$file: forbidden remote tool: $trimmed"
      return 1
    fi

    if [[ "$trimmed" =~ (^|[^A-Za-z0-9_-])rsync[[:space:]] && "$trimmed" != *"command -v rsync"* && "$trimmed" != *"die "* && "$trimmed" != *"echo "* ]]; then
      if [[ "$trimmed" != "$ALLOWED_RSYNC" ]]; then
        echo "$file: rsync is not the allowed read-only pull: $trimmed"
        return 1
      fi
    fi
    if [[ "$trimmed" == *"--remove-source-files"* || "$trimmed" == *"--rsh"* || "$trimmed" == *"rsync -e"* ]]; then
      echo "$file: forbidden rsync option: $trimmed"
      return 1
    fi

    if [[ "$trimmed" =~ (^|[^A-Za-z0-9_\"-])ssh[[:space:]] && "$trimmed" != *"command -v ssh"* && "$trimmed" != *"die "* ]]; then
      # Must be: ssh "$PROD_HOST" '<command>'  or  ssh "$PROD_HOST" "$PROD_EXPORT_CMD"
      if [[ "$trimmed" == *'ssh "$PROD_HOST" "$PROD_EXPORT_CMD"'* ]]; then
        grep -qxF "$EXPORT_CMD_ASSIGNMENT" "$file" || {
          echo "$file: PROD_EXPORT_CMD is not the allowed export"
          return 1
        }
        continue
      fi
      remote="$(printf '%s' "$trimmed" | sed -n "s/.*ssh \"\$PROD_HOST\" '\([^']*\)'.*/\1/p")"
      ok=""
      if [[ -n "$remote" ]]; then
        for allowed in "${ALLOWED_REMOTE[@]}"; do
          if [[ "$remote" == "$allowed" ]]; then ok=1; fi
        done
      fi
      if [[ -z "$ok" ]]; then
        echo "$file: remote command not in the read-only allowlist: $trimmed"
        return 1
      fi
    fi
  done <"$file"
  return 0
}

scripts_to_check() {
  find "$SRC_ROOT/scripts" -type f -name '*.sh' -not -path '*/backup/*' | sort
}

@test "every ssh and rsync call in scripts/ is on the read-only allowlist" {
  count=0
  while IFS= read -r f; do
    run check_script "$f"
    echo "$output"
    [ "$status" -eq 0 ]
    count=$((count + 1))
  done < <(scripts_to_check)
  [ "$count" -ge 5 ]
}

@test "the new scripts are among those checked and do use ssh or rsync" {
  list="$(scripts_to_check)"
  [[ "$list" == *"/scripts/pull-db.sh"* ]]
  [[ "$list" == *"/scripts/sync-env-versions.sh"* ]]
  [[ "$list" == *"/scripts/pull-uploads.sh"* ]]
  grep -q 'ssh "\$PROD_HOST"' "$SRC_ROOT/scripts/pull-db.sh"
  grep -q 'ssh "\$PROD_HOST"' "$SRC_ROOT/scripts/sync-env-versions.sh"
  grep -q 'rsync -a --delete' "$SRC_ROOT/scripts/pull-uploads.sh"
}

@test "the check catches remote commands that could write (self-test)" {
  bad="$BATS_TEST_TMPDIR/bad.sh"
  for cmd in \
    "ssh \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp option update siteurl x'" \
    "ssh \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp plugin update --all'" \
    "ssh \"\$PROD_HOST\" 'rm -rf ~/devnel.blog/backups'" \
    "ssh \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp db export - --single-transaction > /tmp/x.sql'" \
    "ssh triton.devnel.com 'cd ~/devnel.blog/public && wp core version'" \
    "ssh \"\$PROD_HOST\" \"\$SOMETHING_ELSE\"" \
    "ssh -o BatchMode=yes host 'ls'" \
    "scp dump.sql triton.devnel.com:/tmp/" \
    "rsync -a --delete \"\$dest/\" \"\$PROD_HOST:\$REMOTE_UPLOADS\"" \
    "rsync -a --remove-source-files \"\$PROD_HOST:\$REMOTE_UPLOADS\" \"\$dest/\"" \
    "rsync -a -e 'ssh -i key' \"\$PROD_HOST:\$REMOTE_UPLOADS\" \"\$dest/\""; do
    printf '%s\n' "$cmd" >"$bad"
    run check_script "$bad"
    if [ "$status" -eq 0 ]; then
      echo "not caught: $cmd"
      return 1
    fi
  done
}

@test "the check accepts the three allowed remote commands and the allowed rsync (self-test)" {
  good="$BATS_TEST_TMPDIR/good.sh"
  {
    echo "$EXPORT_CMD_ASSIGNMENT"
    echo 'ssh "$PROD_HOST" "$PROD_EXPORT_CMD" |'
    echo "core=\"\$(ssh \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp core version')\" || die x"
    echo "p=\"\$(ssh \"\$PROD_HOST\" 'cd ~/devnel.blog/public && wp plugin list --fields=name,version,status --format=json')\""
    echo "$ALLOWED_RSYNC"
    echo '# ssh "$PROD_HOST" '"'"'rm -rf /'"'"' in a comment is fine'
    echo 'command -v ssh >/dev/null || die "ssh not found"'
  } >"$good"
  run check_script "$good"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "an export command that differs from the allowed one is rejected even via the variable (self-test)" {
  bad="$BATS_TEST_TMPDIR/bad2.sh"
  {
    echo "PROD_EXPORT_CMD='cd ~/devnel.blog/public && wp db reset --yes'"
    echo 'ssh "$PROD_HOST" "$PROD_EXPORT_CMD"'
  } >"$bad"
  run check_script "$bad"
  [ "$status" -ne 0 ]
}
