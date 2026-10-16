#!/usr/bin/env bash
# Make wp-env match production's WordPress core and plugin versions.
#
# Reads the versions from production (read-only: `wp core version`, `wp plugin list`) and writes
# .wp-env.override.json, which is gitignored. The committed .wp-env.json is never touched, so exact
# production versions never reach the (public) repository.
#
# Plugins that production runs but that must not run locally (see SKIP_PLUGINS), and plugins with
# no wordpress.org release zip, are left out with a note.
#
# Usage: scripts/sync-env-versions.sh   (then: npm run env:start -- --update)
# Environment (mostly for tests): DEVNEL_PROD_HOST.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROD_HOST="${DEVNEL_PROD_HOST:-triton.devnel.com}"
OVERRIDE="$root/.wp-env.override.json"
# Production-only plugins: remote management, mail, backups, caches, and an unused offload plugin.
SKIP_PLUGINS=" worker post-smtp updraftplus nginx-cache redis-cache amazon-s3-and-cloudfront "

die() {
  printf '[env:sync] ERROR: %s\n' "$*" >&2
  exit 1
}
note() { printf '[env:sync] %s\n' "$*" >&2; }

# Read-only commands on production.
core="$(ssh "$PROD_HOST" 'cd ~/devnel.blog/public && wp core version')" || die "could not read the core version"
core="$(printf '%s' "$core" | tr -d '[:space:]')"
[[ "$core" =~ ^[0-9]+(\.[0-9]+){1,2}([-.][0-9A-Za-z]+)?$ ]] || die "unexpected core version output"

plugins_json="$(ssh "$PROD_HOST" 'cd ~/devnel.blog/public && wp plugin list --fields=name,version,status --format=json')" ||
  die "could not read the plugin list"

rows="$(printf '%s' "$plugins_json" | node -e '
  const rows = JSON.parse(require("fs").readFileSync(0, "utf8"));
  if (!Array.isArray(rows)) { process.exit(1); }
  for (const r of rows) { console.log([r.name, r.version, r.status].join("\t")); }
')" || die "could not parse the plugin list"

urls=""
while IFS=$'\t' read -r name version status; do
  [[ -n "$name" ]] || continue
  # mu-plugins and drop-ins can't be installed from wordpress.org.
  [[ "$status" == "active" || "$status" == "inactive" ]] || continue
  if [[ ! "$name" =~ ^[a-z0-9-]+$ || ! "$version" =~ ^[0-9][0-9A-Za-z.+-]*$ ]]; then
    note "skipping a plugin with an unexpected name or version"
    continue
  fi
  if [[ "$SKIP_PLUGINS" == *" $name "* ]]; then
    note "skipping $name (production only)"
    continue
  fi
  url="https://downloads.wordpress.org/plugin/$name.$version.zip"
  if curl -fsI -o /dev/null "$url"; then
    urls="$urls$url"$'\n'
  else
    note "skipping $name: no wordpress.org release zip for the production version"
  fi
done <<<"$rows"

tmp="$OVERRIDE.tmp.$$"
printf '%s' "$urls" | CORE="$core" node -e '
  const urls = require("fs").readFileSync(0, "utf8").split("\n").filter(Boolean);
  const out = { core: "WordPress/WordPress#" + process.env.CORE, plugins: urls };
  process.stdout.write(JSON.stringify(out, null, 2) + "\n");
' >"$tmp"
mv -f "$tmp" "$OVERRIDE"

note "wrote .wp-env.override.json (gitignored): core and $(printf '%s' "$urls" | grep -c .) plugin(s) pinned to production's versions"
note "apply it with: npm run env:start -- --update"
