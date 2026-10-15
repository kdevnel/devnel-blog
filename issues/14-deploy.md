# 14. Deploy pipeline

**Wave:** 3 · **Depends on:** 01 · **Implementer:** Sonnet · **Reviewer:** Opus

## Goal
One command deploys a tested theme build to Triton atomically, purges the cache, smoke-checks the site, and can roll back in seconds.

## Context
- Site root and cache path: `docs/SERVER.md`. Production writes are human-gated; once Kyle has approved a deploy, running the script is that step.

## Scope
In: `scripts/build-theme.sh`, `scripts/deploy.sh`, `scripts/rollback.sh`, `scripts/smoke.sh` (shared with 19), release versioning, CHANGELOG.
Out: plugin/core updates (19), nginx changes (11/12).

## Deliverables
- `build-theme.sh`: clean copy of `theme/devnel` to `dist/devnel-<version>/`, `composer install --no-dev --classmap-authoritative` inside it, strip dev files (tests, `.git*`, node files), write `VERSION` with git SHA.
- `deploy.sh [--yes]`:
  1. Refuse if the working tree is dirty or `npm run check` hasn't passed for this commit (marker from CI or local run).
  2. rsync build to `~/devnel.blog/releases/devnel-<version>-<sha>/` on Triton.
  3. Atomically switch symlink `wp-content/themes/devnel → releases/…` (`ln -sfn` to a temp name + `mv -T`). First-time setup documented.
  4. Purge the page cache (`wp nginx-cache purge` if the command exists in the plugin, otherwise `find ~/devnel.blog/cache -type f -delete`), flush the object cache group for highlighting.
  5. Run `smoke.sh https://devnel.blog`; on failure, run `rollback.sh` automatically and exit non-zero.
  6. Keep the last 5 releases; delete older.
- `rollback.sh`: switch symlink to the previous release, purge, smoke.
- `smoke.sh <base>`: the shared smoke check used by 14 and 19. Cache-bypassed (`?nocache=<ts>` per SERVER.md bypass rules) requests to home, latest post (from the feed), a page, `/feed/`, `/wp-sitemap.xml`, `/wp-json/`, `/wp-login.php`, WebFinger, ActivityPub actor. Checks status, the theme marker (05), no "critical error"/"Fatal error" text, response time. Exit codes per failure type, machine-readable summary line.
- Version: theme `Version` in `style.css` bumped by `npm run release <patch|minor|major>` which also updates CHANGELOG and tags.
- Optional `.github/workflows/deploy.yml` (manual `workflow_dispatch` with environment approval) — only if Kyle wants CI deploys; needs an SSH deploy key restricted to the deploy command.

## Acceptance criteria
- [ ] Deploy to a staging target works end to end: use a throwaway directory on Triton (`~/devnel.blog/releases-test/`, not linked) **or** a local container with SSH. Production first deploy is a human-gated step.
- [ ] Symlink switch is atomic (no window where the theme folder is missing).
- [ ] Failing smoke check triggers automatic rollback (proved in the container).
- [ ] Old releases pruned to 5.
- [ ] `smoke.sh` is reusable by 19 (documented interface).

## Tests required
- Bats with stubbed `ssh`/`rsync`/`curl`: dirty tree refusal, symlink switch commands, rollback on smoke failure, pruning.
- Bats for `smoke.sh` against canned responses (200 + marker → pass; 500, missing marker, "critical error" → specific failures).

## Quality notes
- Security: no credentials in scripts (SSH config/agent); deploy key (if CI) uses `command=` restriction in `authorized_keys`.
- Maintenance: deploy and rollback documented in MAINTENANCE.md (17) and README.

## Team lead
Confirm with Kyle whether WordPress accepts a symlinked theme dir on this server (it does by default; check `open_basedir` in the PHP pool, read-only).

## Review focus
- Rollback path really restores the previous state, including cache purge.
- `smoke.sh` bypasses the cache (otherwise a broken release could pass on cached pages).

## Human-gated steps
First production deploy (part of 16), and creating `~/devnel.blog/releases/`.

## Follow-ups
