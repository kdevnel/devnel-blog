#!/usr/bin/env bash
# Run shellcheck over every shell script and Bats over tests/shell.
# Fails clearly if a tool is missing; passes on an empty set of scripts.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

# The linters (shellcheck, bats) come from npm devDependencies (node_modules/.bin),
# or from the system PATH.
export PATH="$root/node_modules/.bin:$PATH"

for tool in shellcheck bats; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "error: '$tool' not found. Run 'npm ci', or install it system-wide (see README)." >&2
    exit 1
  fi
done

scripts=()
while IFS= read -r -d '' file; do
  scripts+=("$file")
done < <(find scripts deploy tools tests/shell -type f \( -name '*.sh' -o -name '*.bash' \) \
  -not -path '*/node_modules/*' -print0 2> /dev/null)

if [ "${#scripts[@]}" -eq 0 ]; then
  echo "shellcheck: no shell scripts yet, nothing to check."
else
  echo "shellcheck: checking ${#scripts[@]} script(s)"
  shellcheck "${scripts[@]}"
fi

tests=()
while IFS= read -r -d '' file; do
  tests+=("$file")
done < <(find tests/shell -type f -name '*.bats' -print0 2> /dev/null)

if [ "${#tests[@]}" -eq 0 ]; then
  echo "bats: no tests yet, nothing to run."
else
  bats "${tests[@]}"
fi
