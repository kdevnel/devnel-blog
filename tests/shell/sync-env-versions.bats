#!/usr/bin/env bats
# Tests for scripts/sync-env-versions.sh with stubbed ssh and curl. All versions here are made up.

load pull_helper

setup() {
  pull_setup
  export STUB_CORE_VERSION="9.8.7"
  export STUB_PLUGINS_JSON='[{"name":"alpha","version":"1.2.3","status":"active"},{"name":"beta","version":"4.5","status":"inactive"},{"name":"worker","version":"2.0","status":"active"},{"name":"post-smtp","version":"3.0","status":"active"},{"name":"gh-only","version":"0.1","status":"active"}]'
}

run_sync() { run "$SYNC"; }

@test "writes the override from the stubbed core and plugin versions" {
  STUB_CURL_FAIL_URL=gh-only run_sync
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$REPO/.wp-env.override.json" ]
  run node -e '
    const o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    console.log(JSON.stringify(o));
  ' "$REPO/.wp-env.override.json"
  [ "$status" -eq 0 ]
  [ "$output" = '{"core":"WordPress/WordPress#9.8.7","plugins":["https://downloads.wordpress.org/plugin/alpha.1.2.3.zip","https://downloads.wordpress.org/plugin/beta.4.5.zip"]}' ]
}

@test "production-only plugins are skipped, and one with no wordpress.org zip is skipped with a note" {
  STUB_CURL_FAIL_URL=gh-only run_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping worker (production only)"* ]]
  [[ "$output" == *"skipping post-smtp (production only)"* ]]
  [[ "$output" == *"skipping gh-only: no wordpress.org release zip"* ]]
  ! grep -q 'worker\|post-smtp\|gh-only' "$REPO/.wp-env.override.json" || false
}

@test "mu-plugins and drop-ins are ignored" {
  STUB_PLUGINS_JSON='[{"name":"ok-one","version":"1.0","status":"active"},{"name":"0-mu","version":"1.0","status":"must-use"},{"name":"object-cache.php","version":"","status":"dropin"}]' run_sync
  [ "$status" -eq 0 ]
  [ "$(grep -c 'downloads.wordpress.org' "$REPO/.wp-env.override.json")" -eq 1 ]
  [[ "$output" != *"unexpected"* ]]
}

# sha_of <file>: SHA-256 (sha256sum on Linux, shasum on macOS).
sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

@test "the override file is mode 600 even under a permissive umask" {
  umask 000
  run_sync
  [ "$status" -eq 0 ]
  [ "$(mode_of "$REPO/.wp-env.override.json")" = 600 ]
}

@test "never writes .wp-env.json" {
  before="$(sha_of "$REPO/.wp-env.json")"
  run_sync
  [ "$status" -eq 0 ]
  [ "$(sha_of "$REPO/.wp-env.json")" = "$before" ]
}

@test "the only remote commands are the two read-only version reads" {
  run_sync
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ssh ' "$STUB_LOG")" -eq 2 ]
  grep -qxF 'ssh triton.devnel.com cd ~/devnel.blog/public && wp core version' "$STUB_LOG"
  grep -qxF 'ssh triton.devnel.com cd ~/devnel.blog/public && wp plugin list --skip-update-check --skip-plugins --skip-themes --fields=name,version,status --format=json' "$STUB_LOG"
}

@test "ssh failure: non-zero, and an existing override is left as it was" {
  echo '{"keep":"me"}' >"$REPO/.wp-env.override.json"
  STUB_SSH_RC=255 run_sync
  [ "$status" -ne 0 ]
  [ "$(cat "$REPO/.wp-env.override.json")" = '{"keep":"me"}' ]
  [ -z "$(find "$REPO" -name '*.tmp.*')" ]
}

@test "a failing plugin list leaves the existing override alone" {
  echo '{"keep":"me"}' >"$REPO/.wp-env.override.json"
  STUB_SSH_RC=1 STUB_SSH_FAIL_AT="plugin list" run_sync
  [ "$status" -ne 0 ]
  [ "$(cat "$REPO/.wp-env.override.json")" = '{"keep":"me"}' ]
}

@test "garbage from ssh is not written into the override" {
  STUB_CORE_VERSION='<html>nope' run_sync
  [ "$status" -ne 0 ]
  [ ! -f "$REPO/.wp-env.override.json" ]
}

@test "a plugin with an unexpected name or version is skipped, not written" {
  STUB_PLUGINS_JSON='[{"name":"ok-one","version":"1.0","status":"active"},{"name":"bad/../name","version":"1.0","status":"active"},{"name":"evil","version":"1.0;rm","status":"active"}]' run_sync
  [ "$status" -eq 0 ]
  [ "$(grep -c 'downloads.wordpress.org' "$REPO/.wp-env.override.json")" -eq 1 ]
  grep -q 'ok-one.1.0.zip' "$REPO/.wp-env.override.json"
}

@test "the override file is gitignored, so production versions can't be committed" {
  run grep -qx '\.wp-env\.override\.json' "$SRC_ROOT/.gitignore"
  [ "$status" -eq 0 ]
}
