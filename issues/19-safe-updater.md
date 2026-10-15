# 19. Safe auto-updater on Triton

**Wave:** R · **Depends on:** 18 (and 20 to enable majors; it can ship with majors held) · **Implementer:** **Opus** (production automation with rollback) · **Reviewer:** Opus

## Goal
WordPress core and plugins stay current automatically. Each update is applied **one at a time**, checked against the live site, and **rolled back** if anything breaks. Kyle hears about every update, rollback and hold.

## Context
- devnel-ops known problem 1: native auto-updates aren't running. The updater isn't disabled, but the `wp_maybe_auto_update` cron event is missing. Pending versions are in `../devnel-ops/SERVER-AUDIT.md`.
- DECISIONS D9: one updater owns updates, so native background updates get turned off.
- WP-Cron runs from system cron every 5 minutes (`wp cron event run --due-now`).
- Smoke check script comes from 14 (`scripts/smoke.sh`). If 14 isn't done yet, build `smoke.sh` here to the interface 14 describes and 14 reuses it.

## Scope
In: root-cause note, mu-plugin to disable native updates, `scripts/update/safe-update.sh`, policy config, held list, notifications, heartbeat, tests, runbook.
Out: theme updates (deployed by 14), the other Triton sites (config-ready, not enabled).

## Deliverables
1. **Root cause** (read-only investigation, written up in `../devnel-ops/SERVER-AUDIT.md`; the public PR only links to it): why `wp_maybe_auto_update` isn't scheduled (e.g. events cleared by a past plugin such as W3TC/Jetpack, or `wp_schedule_update_checks` not firing under WP-CLI cron). Not strictly needed since we're replacing it, but needed to be sure nothing else is broken in cron.
2. `deploy/mu-plugins/devnel-updates.php`: `add_filter('automatic_updater_disabled', '__return_true')` **only for core and plugins** (keep translation updates, or handle them in the script); `auto_update_plugin` and `auto_update_theme` → false; hide auto-update toggles in wp-admin with a note "Managed by safe-update.sh". Alternatively `WP_AUTO_UPDATE_CORE false` in wp-config (coordinate with 12).
3. `scripts/update/safe-update.sh <site-config> [--dry-run] [--only <slug>] [--allow-major <slug>]`:
   - **Lock** (`flock`) so runs never overlap; abort if a deploy (14) is in progress (shared lock file).
   - **Preflight:** backup marker (18) < 26h old, otherwise run `backup.sh` DB-only now; disk check; `wp core verify-checksums` and `wp plugin verify-checksums --all` (warn, don't abort, for plugins without checksums); baseline `smoke.sh` must pass (if the site is already broken, don't update; alert).
   - **Plan:** `wp core check-update --format=json`, `wp plugin list --update=available --format=json`; classify each as patch/minor/major (semver compare; WordPress core major = x.y change); apply **policy** (`config/update-policy.json`): auto = core minor, plugin patch/minor; gated = core major, plugin major, betas, anything in `held.json`; gated items apply only when `canary.json` (20) lists that exact version as passed **and** its release is ≥ 3 days old (`soak_days`).
   - **Apply each, in order** (core first, then plugins alphabetically, but `redis-cache` last, since it swaps the object-cache drop-in):
     1. Snapshot: `rsync -a` the plugin dir (or `wp-admin`, `wp-includes`, root `*.php` for core) to `~/devnel.blog/update-snapshots/<run>/`; note the DB schema version options (`db_version`, plugin `*_db_version` options).
     2. Update: `wp core update --minor` / `wp core update --version=X` or `wp plugin update <slug> --version=X` (exact version from the plan; never "latest" blindly).
     3. `wp core update-db` (core), plugin DB upgrades as their own WP-CLI commands where they exist (e.g. `wp redis update-dropin` after redis-cache).
     4. Purge page cache and object cache.
     5. `smoke.sh` + PHP fatal check: new lines in `logs/error.log` and the PHP-FPM log matching `PHP Fatal|PHP Parse|Uncaught` since the step started.
     6. **On failure:** restore the snapshot; if the DB schema option changed, restore the DB from the preflight dump (single-author blog, 4 a.m., so losing a few minutes is acceptable; document it); purge; re-run smoke; add `{slug, version, reason, date}` to `held.json`; continue with the next item only if the restore smoke passes, otherwise **stop everything and alert as critical**.
   - **Translations:** `wp language core update`, `wp language plugin update --all` at the end, then a smoke check.
   - **Report:** append JSON lines to `~/devnel.blog/logs/updates.log`; send an email summary (updated / rolled back / held / skipped-gated) through `wp eval 'wp_mail(…)'` (Post SMTP), only if something happened or failed; heartbeat ping on every completed run (separate check from backups).
   - **Prune** snapshots older than 14 days.
4. `config/update-policy.json` (in git, deployed with the script): policy above, `soak_days: 3`, canary URL, alert email, heartbeat URL placeholder (real URL in the server-side env file), excluded plugins list.
5. `deploy/cron/updates.cron`: nightly 04:00 (after backups at 03:15 and the restore test window; not overlapping 05:00 jobs).
6. `docs/runbooks/updates.md`: install, first supervised run, reading `updates.log`, releasing a hold (`--only <slug> --allow-major`), manual major updates, disabling the updater in an emergency.

## Acceptance criteria
- [ ] Root cause documented.
- [ ] Bats suite passes (see below), covering every branch of the apply/rollback flow.
- [ ] Full dry run against wp-env (with the production plugin set at the **current production versions**, so updates are pending) applies updates one at a time and passes smoke after each.
- [ ] **Forced failure test** in wp-env: a fake plugin update that fatals (a local zip served as the "new version") gets rolled back automatically, held, reported, and the site passes smoke afterwards.
- [ ] Gated updates (Redis Cache 3.0, WP 7.x) are skipped unless canary.json approves them and the soak time has passed; tested with fixture canary files.
- [ ] Overlap protection: a second concurrent run exits immediately.
- [ ] Native updates are off (`wp eval 'var_dump(wp_is_auto_update_enabled_for_type("plugin"));'` → false, and `automatic_updater_disabled` true) after the mu-plugin is installed.
- [ ] First supervised run on production (human-gated, part of 15) completes with all results recorded.

## Tests required
- Bats with stubbed `wp`, `curl`, `rsync`, `flock`, `mail`: classification (patch/minor/major/beta); policy decisions (auto vs gated vs held); canary approval and soak; per-step snapshot → update → smoke → rollback; DB restore triggered only on schema change; stop-everything when the rollback smoke fails; lock contention; report content; dry-run makes no changes (assert no mutating `wp` calls).
- PHPUnit for the mu-plugin filters.
- `shellcheck` clean.

## Quality notes
- Security: runs as `kyle`; no secrets in git; the canary fetch is HTTPS GET only and its JSON is validated (schema) before use. A tampered canary can at most allow an update from wordpress.org, never run code.
- Maintenance: everything logged; held list is human-readable; documented release of holds.
- Performance: runs at 04:00; cache purges only when something changed.

## Team lead
1. Investigate the root cause first (read-only) and share it with Kyle before briefing.
2. After merge: install on Triton with Kyle (runbook), do the supervised first run (that's issue 15 step 2), then let it run nightly and check the first 3 reports.

## Review focus
- Every failure path ends in a working site or a loud critical alert, never silent.
- Rollback restores exactly what the step changed (plugin dir names vs slugs, drop-ins like `object-cache.php`).
- Version comparison is correct for WordPress-style versions (`6.10.1` > `6.9.12`, `2.0.0-beta.1` < `2.0.0`).
- Dry run is really read-only.
- Smoke checks bypass the page cache.

## Human-gated steps
1. Installing the mu-plugin and/or the wp-config constant.
2. Installing the script, config and cron entry.
3. The first supervised run (issue 15).

## Follow-ups
- Add the other sites on Triton (listed in devnel-ops) via config (separate issue, Kyle's call).
