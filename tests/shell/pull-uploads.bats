#!/usr/bin/env bats
# Tests for scripts/pull-uploads.sh with stubbed rsync and git.

load pull_helper

setup() { pull_setup; }

@test "rsync -a --delete with the remote as the source and .data/uploads as the destination" {
  run "$UPLOADS"
  [ "$status" -eq 0 ]
  line="$(grep '^rsync ' "$STUB_LOG")"
  [ "$line" = "rsync -a --delete --delete-excluded --exclude-from=$(cd "$REPO" && pwd)/scripts/sanitise/uploads-exclude.txt triton.devnel.com:devnel.blog/public/wp-content/uploads/ $(cd -P "$DATA" && pwd)/uploads/" ]
}

@test "never --remove-source-files, and the remote is never the destination" {
  run "$UPLOADS"
  [ "$status" -eq 0 ]
  ! grep -q 'remove-source' "$STUB_LOG" || false
  ! grep -q 'rsync .* /.* [a-z.]*:' "$STUB_LOG" || false
  ! grep -q '^ssh ' "$STUB_LOG" || false
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
  ! grep -q '^rsync' "$STUB_LOG" || false
}

@test "the exclude list keeps private plugin files out and everything else in (real rsync, local copy)" {
  real=/usr/bin/rsync
  [ -x "$real" ] || skip "no /usr/bin/rsync"
  ! "$real" --version 2>&1 | grep -qi openrsync || skip "macOS openrsync cannot do this local copy; CI covers it"
  src="$BATS_TEST_TMPDIR/src"
  dst="$BATS_TEST_TMPDIR/dst"
  mkdir -p "$src/2026/10" "$src/zbscrm-store/_wip" "$src/jpcrm-storage" "$src/invoices" "$src/wpforms" "$src/gravity_forms" \
    "$src/post-smtp-logs" "$src/updraft" "$src/backup-2026" "$src/plugin/nested" "$dst/zbscrm-store"
  touch "$src/2026/10/photo.jpg" "$src/2026/10/doc.pdf" "$src/plugin/nested/asset.png" \
    "$src/zbscrm-store/client.pdf" "$src/zbscrm-store/_wip/import.csv" "$src/jpcrm-storage/x.pdf" "$src/invoices/inv.pdf" \
    "$src/wpforms/entry.pdf" "$src/gravity_forms/f.pdf" "$src/post-smtp-logs/l.txt" "$src/updraft/b.zip" \
    "$src/backup-2026/b.tar" "$src/dump.sql" "$src/dump.sql.gz" "$src/site.log" "$src/archive.zip" "$src/plugin/nested/keep.zip"
  touch "$dst/zbscrm-store/stale-from-an-earlier-copy.pdf" "$dst/gone-from-production.jpg"
  "$real" -a --delete --delete-excluded --exclude-from="$SRC_ROOT/scripts/sanitise/uploads-exclude.txt" "$src/" "$dst/"
  [ -f "$dst/2026/10/photo.jpg" ]
  [ -f "$dst/2026/10/doc.pdf" ]
  [ -f "$dst/plugin/nested/asset.png" ]
  [ ! -e "$dst/gone-from-production.jpg" ]
  for f in zbscrm-store jpcrm-storage invoices wpforms gravity_forms post-smtp-logs updraft backup-2026 \
    dump.sql dump.sql.gz site.log archive.zip plugin/nested/keep.zip; do
    [ ! -e "$dst/$f" ] || {
      echo "copied: $f"
      return 1
    }
  done
}

@test "an rsync failure is a failure" {
  STUB_RSYNC_RC=23 run "$UPLOADS"
  [ "$status" -ne 0 ]
}
