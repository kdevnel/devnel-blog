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

## Decisions (lead, 2026-10-16)
Kyle approved streaming the export "as long as it's secure". Where these differ from Deliverables, these win.

1. **Raw production data never touches disk and never enters wp-env.** `scripts/pull-db.sh` streams `ssh triton.devnel.com 'cd ~/devnel.blog/public && wp db export - --single-transaction'` into a throwaway, isolated MySQL container (`docker run`, `--network none`, no published ports, random name, `mysql:8.4`, removed by a trap on every exit path). Sanitising is plain SQL inside that container. `scripts/check-sanitised.sh` runs against the container; on failure the script aborts with nothing imported. Only then is the sanitised DB exported to `.data/sanitised-YYYYMMDD.sql.gz` and imported into wp-env, followed by `wp search-replace` (URLs only), a permalink flush, a second `check-sanitised.sh` run against wp-env, and a summary. No raw dump file is ever written; a failure leaves wp-env untouched.
2. **Files:** `.data/` is mode 700, `.data/*.sql.gz` mode 600 (umask 077). The last 3 sanitised snapshots are kept. The script refuses to run if `.data` is not gitignored (`git check-ignore`).
3. **No exact production versions in git.** `.wp-env.json` pins `phpVersion: "8.4"` and a CI-usable core/plugin set (a pinned WordPress release, wordpress.org plugin zips). `scripts/sync-env-versions.sh` (`npm run env:sync`) reads production core and plugin versions read-only and writes the gitignored `.wp-env.override.json`. Documented in `docs/LOCAL.md`, Bats-tested with a stubbed ssh.
4. **Sanitisation list** (users, usermeta, comments, commentmeta, truncated tables, deleted options, transients, plugin deactivation) is written once in `scripts/sanitise/` and used by both the sanitiser and `check-sanitised.sh`, which fails on any leftover and prints table and column names, never values.
5. **wp-env exposure** is investigated and documented in `docs/LOCAL.md`; only sanitised data ever reaches wp-env.
6. **Uploads sync:** `rsync -a --delete` into `.data/uploads` with the remote as source only, never `--remove-source-files`.
7. CI runs the pipeline only with stubs; a real snapshot is never used in CI.
8. An extra Bats test greps every new script for ssh commands and fails if a remote command could write (allowed: `wp db export -`, `wp core version`, `wp plugin list`, rsync with the remote as source).

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

### Added during implementation (needs the lead's ack)
The first real run showed the decisions' list was not enough for the check to pass, so the sanitiser also does the following (all data-driven, in `scripts/sanitise/`, and tested):
- Removes cached third-party posts (`ap_actor`, `ap_inbox`, `ap_outbox`, `friend_post_cache`) with their meta, term relationships and comments. ActivityPub's remote-actor cache is by far the largest table content and holds other people's profiles, bios with email addresses and public keys.
- Deletes postmeta keys that hold contact-form and payment recipients (`_g_feedback_shortcode*`, `spay_email`) and the option `auto_core_update_notified` (it records the admin email).
- Replaces any remaining email address in `post_title`, `post_excerpt` and `post_content` with `redacted@example.test` instead of allowlisting the author's public address, so no real address is committed to this public repository.
- Before the final wp-env check, deletes the listed options once more, because WordPress writes fresh transients during the pull.
- The email and PEM checks scan every text column of every table, not only the tables named in the decisions.

Noted for later:
- wp-env publishes its ports on all interfaces and has no setting to change that (see `docs/LOCAL.md`).
- `friends-autoresolve-links` and `friends-post-collection` have no wordpress.org zip, so they are not installed locally.
- `CLAUDE.md`'s command list could mention `env:sync`, `db:check` and `uploads:pull` (not edited here).
