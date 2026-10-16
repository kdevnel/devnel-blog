# Shared setup for the pull-db, check-sanitised, sync-env-versions and pull-uploads tests.
# Builds a throwaway copy of the repository's scripts/ under $BATS_TEST_TMPDIR/repo (so the
# scripts' default paths, such as .data and .wp-env.json, land in a temp directory) and puts the
# stubs in tests/shell/stubs first on PATH. Nothing here touches production, docker or wp-env.
# The variables are used from the .bats files, which the linter can't see from here.
# shellcheck disable=SC2034

SRC_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

pull_setup() {
  REAL_GZIP="$(command -v gzip)"
  export REAL_GZIP
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  : >"$STUB_LOG"
  export STUB_SQL_DIR="$BATS_TEST_TMPDIR/sql"
  mkdir -p "$STUB_SQL_DIR"
  export PATH="$SRC_ROOT/tests/shell/stubs:$PATH"
  # No waiting between readiness checks in tests.
  export DEVNEL_READY_SLEEP=0
  export DEVNEL_READY_TRIES=3

  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  cp -R "$SRC_ROOT/scripts" "$REPO/scripts"
  printf '{ "core": "WordPress/WordPress#0.0.0" }\n' >"$REPO/.wp-env.json"
  PULL="$REPO/scripts/pull-db.sh"
  CHECK="$REPO/scripts/check-sanitised.sh"
  SYNC="$REPO/scripts/sync-env-versions.sh"
  UPLOADS="$REPO/scripts/pull-uploads.sh"
  DATA="$REPO/.data"
}

# mode_of <path>: octal permission bits (GNU then BSD stat).
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# line_no <pattern>: the number of the first line of the stub log matching a grep pattern (empty if none).
line_no() { grep -n -m1 -- "$1" "$STUB_LOG" | cut -d: -f1; }

# the name of the container the script started
container_name() { sed -n 's/^docker run .*--name \([^ ]*\) .*/\1/p' "$STUB_LOG" | head -1; }

# container_removed: the container that was started was removed with `docker rm -f -v <name>`.
container_removed() {
  local n
  n="$(container_name)"
  [[ -n "$n" ]] && grep -q "^docker rm -f -v $n\$" "$STUB_LOG"
}

# nothing_in_wpenv: the stubbed wp-env never saw an import, a search-replace or a flush.
nothing_in_wpenv() {
  ! grep -qE '^wp-env wp (db import|search-replace|rewrite|user|plugin)' "$STUB_LOG" || false
}
