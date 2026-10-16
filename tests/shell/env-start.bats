#!/usr/bin/env bats
# Tests for scripts/env-start.sh with a stubbed npx.

load pull_helper

setup() { pull_setup; }

@test "creates the mapped directories, makes .data 700, and passes arguments to wp-env" {
  umask 000
  run "$REPO/scripts/env-start.sh" --update
  [ "$status" -eq 0 ]
  [ -d "$REPO/.data/uploads" ]
  [ -d "$REPO/tools" ]
  [ "$(mode_of "$REPO/.data")" = 700 ]
  grep -qx 'wp-env start --update' "$STUB_LOG"
}
