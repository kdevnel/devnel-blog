# 16. Launch

**Wave:** 3 · **Depends on:** 07, 09, 10, 11, 12, 13, 14, 15, 18, 19 · **Implementer:** team lead (runbook author and executor) · **Reviewer:** Opus (reviews the runbook before launch day)

## Goal
The devnel theme goes live on devnel.blog with migrated content, no broken URLs, all quality bars met on production, and a tested rollback.

## Context
Everything before this issue. Pre-launch URL inventory from 11 (`docs/url-inventory-pre-launch.txt`).

## Scope
In: `docs/runbooks/launch.md`, execution, post-launch verification, 48-hour watch.
Out: CSP enforcement (scheduled follow-up from 12).

## Deliverables
`docs/runbooks/launch.md`:
1. **T-1 day:** canary (20) green; `npm run check` green on `main`; reviewer signs off the runbook; Kyle picks a time.
2. **Backup:** run `backup.sh` (18) manually; run the restore test; write the backup marker 13 needs.
3. **Deploy theme inactive:** `deploy.sh` (14) installs the release (theme not active yet); smoke still checks the old theme.
4. **Migrate content:** `tools/migrate/run.sh production --apply` (13); save the report.
5. **Activate:** `wp theme activate devnel`; purge cache.
6. **Verify (within 10 minutes):** `smoke.sh` (now expecting the devnel marker); e2e smoke + axe against production (`BASE_URL=https://devnel.blog npm run test:prod`, read-only specs only); Lighthouse against production; `url-inventory.sh` → diff against pre-launch (every old URL 200 or a 301 to the right place); sitemap 200; ActivityPub actor + WebFinger OK; post a test comment on a test post, then delete it.
7. **Deactivate SyntaxHighlighter** once code blocks are confirmed highlighted.
8. **Rollback** (if any step 6 check fails and can't be fixed in 15 minutes): `wp theme activate twentytwentyfive`, purge; content migration stays (it's compatible with TT5) or revert via revisions if needed.
9. **Update `safe-update.sh` config** so the smoke marker is the devnel theme marker.
10. **48-hour watch:** error log, `csp.log`, Fediverse delivery, the safe updater's first unattended run.
11. **After:** Kyle submits the sitemap in Google Search Console / Bing (optional); delete the 9 TT5 Site Editor customisations only after a month (keep for rollback).

## Acceptance criteria
- [ ] Runbook reviewed (Opus reviewer pass) before launch day.
- [ ] All verification checks pass on production; results recorded in this issue.
- [ ] URL diff shows no unexpected 404s.
- [ ] Lighthouse on production: ≥ 95 performance, 100 for the rest, on home, a post, an archive.
- [ ] Rollback tested on wp-env beforehand (switch themes back and forth with migrated content).

## Tests required
- `tests/e2e/prod/*.spec.ts`: read-only specs (no form posts except the explicit test comment step done by hand) runnable against production.

## Quality notes
All six areas get verified on production here.

## Team lead
Run the runbook live with Kyle; stop on any failed check; log times and outcomes in this issue.

## Review focus (runbook review)
- Order of operations (backup before migration; theme installed before activation).
- Every step has a verification and a rollback.

## Human-gated steps
All of them.

## Follow-ups
- CSP report-only → enforce (12) after 7 clean days.
- HSTS max-age ramp (12).
