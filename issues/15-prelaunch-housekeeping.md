# 15. Pre-launch housekeeping

**Wave:** 3 · **Depends on:** 19 · **Implementer:** Haiku (writes the checklist and commands) · **Reviewer:** Sonnet · **Executor:** team lead, with Kyle approving each step

## Goal
Production is current, tidy and free of leftovers before the new theme goes live, so launch problems can't be confused with old ones.

## Context
- `docs/SERVER.md` → "Plugins"; devnel-ops known problems 1 and 5 and its plugin versions.
- The safe updater (19) does the actual updates. Its first supervised run is the core of this issue.

## Scope
In: a runbook in `docs/runbooks/prelaunch.md` and its execution.
Out: theme work, content migration (13 runs at launch).

## Deliverables
`docs/runbooks/prelaunch.md` with, for each step: command, expected output, how to verify, how to undo.
1. Verified backup (issue 18 restore test green within 24h).
2. First supervised `safe-update.sh` run: core → latest 6.9.x minor; plugins → latest minor/patch. Post SMTP moves from its pre-release version (see devnel-ops) to the latest stable. Note: going from a pre-release to stable can be a semver "major" for the policy, so allow it explicitly for this run and record why.
3. Majors (pending majors are listed in devnel-ops) only once the canary (20) passes them; otherwise schedule after launch.
4. Clean `auto_update_plugins` of uninstalled plugins (jetpack, jetpack-protect, jetpack-boost, w3-total-cache, gutenberg, crowdsignal-forms, polldaddy). Moot once 19 disables native updates, but tidy anyway.
5. Remove the inactive `stewart` theme and `amazon-s3-and-cloudfront` (confirm unused: check `wp option get tantan_wordpress_s3` and that uploads aren't offloaded).
6. Confirm `worker` is still wanted; remove if not.
7. Record the before/after `wp plugin list` and `wp core version` in `../devnel-ops/SERVER-AUDIT.md` (not in this public repo); the issue notes only that it was done.

## Acceptance criteria
- [ ] Runbook written and reviewed.
- [ ] All steps executed with Kyle's approval, results recorded.
- [ ] Smoke check (14's `smoke.sh`) green after the run.
- [ ] devnel-ops audit updated with the new versions; SERVER.md plugin table updated if plugins were removed.

## Tests required
None beyond `smoke.sh`.

## Quality notes
- Maintenance: fewer plugins, fewer updates, less to go wrong.

## Team lead
Execute step by step; never batch approvals. Stop at the first failed verification.

## Review focus
- Every step has an undo.
- Nothing removed that's still referenced (S3 offload, Worker).

## Human-gated steps
All of them.

## Follow-ups
