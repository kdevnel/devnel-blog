#!/usr/bin/env bash
# Copy production's uploads into .data/uploads (mapped into wp-env as wp-content/uploads).
#
# Read-only on production: the remote is only ever the rsync *source*, and --remove-source-files is
# never used. --delete removes files from the local copy that no longer exist on production, and
# --delete-excluded also removes anything scripts/sanitise/uploads-exclude.txt keeps out (private
# plugin files), in case an earlier copy had it.
#
# Usage: scripts/pull-uploads.sh
# Environment (mostly for tests): DEVNEL_PROD_HOST, DEVNEL_DATA_DIR.
set -euo pipefail
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROD_HOST="${DEVNEL_PROD_HOST:-triton.devnel.com}"
DATA_DIR="${DEVNEL_DATA_DIR:-$root/.data}"
EXCLUDE_FILE="$root/scripts/sanitise/uploads-exclude.txt"
REMOTE_UPLOADS="devnel.blog/public/wp-content/uploads/"

die() {
  printf '[pull-uploads] ERROR: %s\n' "$*" >&2
  exit 1
}

command -v rsync >/dev/null 2>&1 || die "rsync not found"
[[ -f "$EXCLUDE_FILE" ]] || die "missing $EXCLUDE_FILE"

mkdir -p "$DATA_DIR"
chmod 700 "$DATA_DIR"
data_real="$(cd -P "$DATA_DIR" && pwd)"
root_real="$(cd -P "$root" && pwd)"
if [[ "$data_real" == "$root_real" || "$data_real" == "$root_real"/* ]]; then
  git -C "$root" check-ignore -q -- "$data_real/uploads/probe" ||
    die "$data_real is not gitignored; refusing to copy uploads there"
fi

dest="$data_real/uploads"
mkdir -p "$dest"
# Never --delete into anything but the uploads directory under the data directory.
[[ "$dest" == "$data_real/uploads" && "$dest" != "/" ]] || die "unsafe destination"

echo "[pull-uploads] rsync $PROD_HOST:$REMOTE_UPLOADS -> ${dest#"$root_real"/}" >&2
rsync -a --delete --delete-excluded --exclude-from="$EXCLUDE_FILE" "$PROD_HOST:$REMOTE_UPLOADS" "$dest/"
echo "[pull-uploads] done" >&2
