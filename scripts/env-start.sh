#!/usr/bin/env bash
# Start wp-env. Makes sure the directories that .wp-env.json maps into the site exist first
# (.data/uploads, and tools/), with .data private (mode 700). Extra arguments go to wp-env,
# for example `npm run env:start -- --update` after `npm run env:sync`.
set -euo pipefail
umask 077

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

mkdir -p .data/uploads tools
chmod 700 .data

exec npx wp-env start "$@"
