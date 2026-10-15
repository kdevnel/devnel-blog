# 02. Local environment mirroring production

**Wave:** 0 · **Depends on:** 01 · **Implementer:** Sonnet · **Reviewer:** Opus (data handling, prod read-only)

## Goal
`npm run env:start` gives a local WordPress that matches production closely (versions, plugins, permalinks), and `npm run db:pull` loads a **sanitised** copy of the real content into it.

## Context
- Production facts: `docs/SERVER.md` (PHP 8.4, plugin list, permalinks, site root); exact core and plugin versions in `../devnel-ops/SERVER-AUDIT.md`.
- Guardrail: production is read-only (CLAUDE.md #1, #2).

## Scope
In: `.wp-env.json`, `.wp-env.override.json` example, pull/sanitise script, uploads sync script, npm scripts.
Out: test suites (03), fixture content for CI (03), Redis/nginx emulation (not needed locally).

## Deliverables
- `.wp-env.json`: `core` pinned to the production version (`WordPress/WordPress#<prod version>`, bumped when prod moves), `phpVersion: "8.4"`, themes `./theme/devnel`, plugins from wordpress.org zips matching production (activitypub, friends, friends-autoresolve-links, friends-post-collection, akismet, redirection, syntaxhighlighter — until 13 lands), `config` with `WP_DEBUG`, `WP_DEBUG_LOG`, `SCRIPT_DEBUG`; mappings for `tools/`. Port 8888 (dev), 8889 (tests).
- `scripts/pull-db.sh`:
  1. `ssh triton.devnel.com 'cd ~/devnel.blog/public && wp db export - --single-transaction' | gzip > .data/prod-YYYYMMDD.sql.gz` (streams; writes nothing on the server).
  2. Imports into wp-env (`wp-env run cli wp db import`).
  3. `wp search-replace https://devnel.blog http://localhost:8888 --all-tables --precise`.
  4. **Sanitise:** every user's email → `userN@example.test` and password reset; commenter emails/IPs/user agents anonymised; delete `wp_options` rows holding secrets (Post SMTP credentials, Akismet key, `worker` keys, UpdraftPlus remote creds; list the option names the script removes); deactivate `worker`, `post-smtp`, `updraftplus`, `nginx-cache`, `redis-cache` locally.
  5. Flushes permalinks, prints a summary (posts/pages/comments counts).
- `scripts/pull-uploads.sh` (optional): `rsync -a --delete` of `wp-content/uploads` from prod into `.data/uploads`, mapped into wp-env.
- npm scripts: `env:start`, `env:stop`, `env:reset`, `db:pull`, `uploads:pull`.
- `docs/LOCAL.md`: setup, the sanitisation guarantee, how to refresh.

## Acceptance criteria
- [ ] `npm run env:start` → site at http://localhost:8888 with the `devnel` theme available, PHP 8.4 and the production WP version (`wp core version`).
- [ ] `npm run db:pull` imports real content; post/page/comment counts match the current production counts.
- [ ] After a pull, no real email addresses, IPs or plugin secrets remain: a check script (`scripts/check-sanitised.sh`) greps the local DB for `@` outside `example.test`, known option names and IP patterns, and fails if it finds any.
- [ ] Nothing in the pull path writes to production (only `wp db export -` to stdout).
- [ ] `.data/` is gitignored and nothing from it is committed.

## Tests required
- Bats test for `pull-db.sh` with stubbed `ssh` and `wp-env` covering: the stream pipeline, the search-replace arguments, sanitise SQL run, and failure when ssh fails (non-zero exit, no partial import).
- `check-sanitised.sh` run as the last step of `db:pull`.

## Quality notes
- Security: PII and secrets never leave Kyle's machine; snapshots never used in CI.
- Maintenance: one place (`.wp-env.json`) to bump versions; document it.

## Team lead
1. Confirm with Kyle that streaming a DB export over SSH is fine (it's read-only).
2. After merge, run `npm run db:pull` once yourself and confirm the sanitisation check passes.

## Review focus
- Any command that could write on Triton.
- Sanitisation covers every place PII lives: `wp_users`, `wp_usermeta`, `wp_comments`, `wp_commentmeta`, ActivityPub/Friends tables and options (followers, remote actors), Akismet tables.
- Secrets in options: list checked against the actual option names on production (`wp option list --search=…`, read-only).

## Human-gated steps
None (read-only export).

## Follow-ups
