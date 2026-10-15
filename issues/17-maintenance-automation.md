# 17. Ongoing maintenance automation

**Wave:** 3 · **Depends on:** 16 · **Implementer:** Sonnet · **Reviewer:** Opus

## Goal
Once the site is live it stays fast, accessible and correct without anyone having to remember to check it, and routine tasks are documented.

## Context
`docs/QUALITY.md` → "Maintenance". The safe updater (19) and canary (20) handle core and plugin updates; this issue covers the theme, production monitoring and docs.

## Scope
In: scheduled production checks, Dependabot tuning, compatibility headers, MAINTENANCE.md.
Out: updater/canary (19/20), backups (18).

## Deliverables
- `.github/workflows/prod-checks.yml` (weekly + manual): Lighthouse on production pages, read-only e2e + axe (`tests/e2e/prod`), link crawl, `wp-sitemap.xml` 200, TLS expiry > 21 days. Opens or updates a single GitHub issue on failure, closes it on recovery.
- Dependabot: group minor/patch updates; auto-merge for dev-dependency patches only when CI passes (if GitHub supports it on the repo).
- Theme header `Tested up to` kept in step with production WordPress: a CI check fails if production's core version (from canary.json or a read-only check) is newer than `Tested up to` for over 14 days.
- `docs/MAINTENANCE.md`:
  - Releasing the theme (version bump, CHANGELOG, deploy, rollback)
  - Updating tokens/fonts (from devnel-com), and re-running contrast and visual baselines
  - Adding a block style or pattern
  - Writing posts: alt text, headings, code block languages (`language-xxx` class), excerpts for descriptions
  - What the safe updater does, how to read `updates.log`, how to release a held plugin, how to apply a major manually
  - Backups: where, how to restore (from 18)
  - Monthly 10-minute checklist (review held updates, disk usage, csp.log, comment spam)

## Acceptance criteria
- [ ] Prod checks workflow runs green against production and opens an issue when a check is forced to fail (test with a bad URL in a branch run).
- [ ] MAINTENANCE.md covers every item above, verified by the reviewer following two procedures end to end on wp-env.
- [ ] Dependabot config validated.

## Tests required
- Workflow dry run (`workflow_dispatch`) evidence in the PR.

## Quality notes
- Security: workflow has read-only permissions except `issues: write`.

## Team lead
Requires the GitHub remote (01). If there isn't one, run prod checks from Triton's cron or Kyle's machine instead and document it.

## Review focus
- Prod checks are strictly read-only against production.

## Human-gated steps
None.

## Follow-ups
