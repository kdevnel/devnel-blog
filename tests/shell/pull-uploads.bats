#!/usr/bin/env bats
# Tests for scripts/pull-uploads.sh with stubbed rsync and git.

load pull_helper

setup() { pull_setup; }

@test "rsync -a --delete with the remote as the source and .data/uploads as the destination" {
  run "$UPLOADS"
  [ "$status" -eq 0 ]
  line="$(grep '^rsync ' "$STUB_LOG")"
  [ "$line" = "rsync -a --delete triton.devnel.com:devnel.blog/public/wp-content/uploads/ $(cd -P "$DATA" && pwd)/uploads/" ]
}

@test "never --remove-source-files, and the remote is never the destination" {
  run "$UPLOADS"
  [ "$status" -eq 0 ]
  ! grep -q 'remove-source' "$STUB_LOG"
  ! grep -q 'rsync .* /.* [a-z.]*:' "$STUB_LOG"
  ! grep -q '^ssh ' "$STUB_LOG"
}

@test "the data directory is 700" {
  mkdir -p "$DATA"
  chmod 755 "$DATA"
  run "$UPLOADS"
  [ "$status" -eq 0 ]
  [ "$(mode_of "$DATA")" = 700 ]
}

@test "refuses to run when .data is not gitignored" {
  STUB_GIT_NOT_IGNORED=1 run "$UPLOADS"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not gitignored"* ]]
  ! grep -q '^rsync' "$STUB_LOG"
}

@test "an rsync failure is a failure" {
  STUB_RSYNC_RC=23 run "$UPLOADS"
  [ "$status" -ne 0 ]
}
