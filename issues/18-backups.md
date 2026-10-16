# 18. Reliable backups

**Wave:** R (start immediately) · **Depends on:** — · **Implementer:** Sonnet · **Reviewer:** Opus (data safety)

## Goal
devnel.blog has backups that are **proven to restore**, are kept off the server, and don't fill the disk. This is the safety net every production-changing issue relies on.

## Context
devnel-ops known problems 2 and 3 (`../devnel-ops/SERVER-AUDIT.md` has the figures):
- `~/scripts/backup.sh` sends mysqldump stderr into the dump (`> file 2>&1`), so line 1 of every dump is a warning and a plain restore fails.
- DB password on the command line.
- Retention `rm` only matches backups from exactly 30 days ago, so nothing is ever deleted and the backlog is filling the disk.
- Backups sit on the same disk as the site; nothing off-site.
- Weekly only (Sunday 05:00), and the whole `public/` tarball (~200 MB) including WordPress core.
- The same script also backs up another site on Triton (named in devnel-ops). **Don't change that site's behaviour**: the new script is separate, and the old cron line for devnel.blog is replaced only.

## Scope
In: new `scripts/backup/backup.sh`, `restore-test.sh`, config, cron entries, off-site sync, alerting, cleanup runbook.
Out: other sites (config-driven so they can be added later), UpdraftPlus configuration (unless Kyle picks it for off-site).

## Deliverables
- `scripts/backup/backup.sh <site-config>`:
  - Reads `~/.config/devnel-backup/<site>.env` (DB name from `wp config get`, paths, off-site target, retention, heartbeat URL). Credentials through a `~/.my.cnf`-style `--defaults-extra-file` (mode 600), never on the command line.
  - `set -euo pipefail`; checks free disk (abort if < 2× expected backup size, alert).
  - DB: `mysqldump --defaults-extra-file=… --single-transaction --quick --routines --triggers --default-character-set=utf8mb4 db 2>>logfile | gzip > tmp`, then verify `gzip -t` and that line 1 starts with `-- MySQL dump`, then atomic `mv`.
  - Files: `wp-content/` only (uploads, themes, plugins, mu-plugins) plus `wp-config.php` encrypted or excluded (decide; default: excluded, store secrets separately), and nginx site config copy. Core is reinstallable.
  - Writes a `last-success` marker with timestamp + checksums (13 and 16 check it).
  - Retention with `find -mtime +N -delete` per type (default: DB daily 14 days, files weekly 8 weeks), local; longer off-site.
  - Off-site: `rclone copy` to a remote Kyle chooses (Backblaze B2, Cloudflare R2, or another server), or UpdraftPlus remote storage if Kyle prefers. Encrypted (rclone `crypt`) since dumps contain commenter data.
  - Heartbeat: ping a dead-man's switch URL on success (e.g. healthchecks.io, self-hostable), and send an email via `wp eval 'wp_mail(…)'` on failure.
- `scripts/backup/restore-test.sh <site-config>` (weekly): restores the latest dump into a scratch database `<db>_restoretest` (created/dropped each run with a dedicated MySQL user limited to that DB), checks table count, `wp_posts` published count and `wp_options` `siteurl` match production, drops it, reports. Optionally fetches the off-site copy instead of the local one (monthly) to prove off-site restores.
- `deploy/cron/backup.cron`: daily DB 03:15, weekly files Sunday 03:30, weekly restore test Monday 04:00. Times avoid the existing 05:00 job for the other site.
- `docs/runbooks/restore.md`: full restore procedure (DB + wp-content + reinstall core), tested once on wp-env.
- `docs/runbooks/backup-cleanup.md`: after the first verified new backup, delete the old `~/devnel.blog/backups/*` backlog (keep the latest old pair until the new system has 2 weeks of history).

## Acceptance criteria
- [x] Bats tests pass (see below): `bats tests/shell/` (50 tests) and `shellcheck` clean.
- [x] On Triton (human-gated install): a manual run produces a dump whose first line is `-- MySQL dump`, a wp-content archive, an off-site copy, and a heartbeat ping.
- [x] `restore-test.sh` passes against that dump on Triton and reports counts matching production.
- [ ] A full restore into wp-env from the off-site copy works, following `docs/runbooks/restore.md`.
- [x] Retention deletes old files (Bats with fake timestamps) and the disk check aborts when space is low.
- [x] No password in `ps` output or in the script; config files mode 600.
- [x] After cleanup, `~/devnel.blog/backups` is under 1 GB and disk usage drops accordingly.

## Tests required
- Bats with stubbed `mysqldump`, `gzip`, `rclone`, `curl`, `wp`, `df`: success path; mysqldump failure → no file replaced, alert sent, non-zero exit; corrupt gzip detected; low disk aborts; retention selects the right files; marker written only on success.
- Bats for `restore-test.sh`: count mismatch fails; scratch DB always dropped (trap).
- `shellcheck` clean.

## Quality notes
- Security: encrypted off-site; dedicated restricted MySQL user for restore tests; no secrets in git.
- Maintenance: one config file per site; logs to `~/devnel.blog/logs/backup.log`.

## Decisions (Kyle, 2026-10-15)
- **Off-site:** Google Drive through rclone: a `drive` remote wrapped in a `crypt` remote. The script only uses the crypt remote name from the site config, so switching to B2/R2/SFTP later is a config change. Because Drive has no lifecycle rules, the script prunes off-site copies itself (`rclone delete --min-age <offsite retention>` on the crypt remote, default DB 90 days / files 26 weeks) and deletes past the Drive trash (`--drive-use-trash=false`, or the equivalent remote config option), otherwise deleted dumps keep using quota. Kyle creates the OAuth token (`rclone authorize "drive"` on a machine with a browser) and the crypt passwords on Triton. The agent never handles them.
- **Heartbeat:** Healthchecks, as hosted healthchecks.io (Kyle chose it at install time over self-hosting; either works, since only the ping URLs differ). Checks use cron schedules in the `Africa/Johannesburg` time zone to match Triton's cron. The script pings `HEARTBEAT_URL` from the config (`/start` at the beginning, the plain URL on success, `/fail` on failure, as the Healthchecks API defines). Hosting it isn't part of this issue, but it shouldn't run on Triton.
- **Heartbeat URLs are per job** (lead, during integration): `HEARTBEAT_URL_DB`, `HEARTBEAT_URL_FILES` and `RESTORE_HEARTBEAT_URL` instead of one `HEARTBEAT_URL`, so a missed weekly files run or restore test raises its own alert.
- **UpdraftPlus:** isn't used for off-site. Whether to remove it is left to issue 15 (noted in Follow-ups).

## Team lead
1. Ask Kyle: off-site destination (and credentials, set up by Kyle on the server, never through the agent), heartbeat service, whether UpdraftPlus stays.
2. Bring the install steps to Kyle as a runbook; supervise the first manual run.

## Review focus
- Failure paths never leave a partial file in place of a good one.
- Restore test can't touch the production DB (separate DB name **and** separate MySQL user without rights on prod).
- The other site's backup (same old script) keeps working unchanged.

## Human-gated steps
1. Creating the MySQL restore-test user and `~/.config/devnel-backup/` files.
2. Installing the cron entries (replacing only the devnel.blog line).
3. First manual run and restore test.
4. Deleting the old backlog (after 2 weeks of new backups).

## Install log (Triton)
Figures (sizes, disk, memory, timings) are in `../devnel-ops`; this log only records what was done and whether it passed.

- **2026-10-15, steps 1–6** (Kyle): Healthchecks checks created on healthchecks.io (cron schedules, `Africa/Johannesburg`). Scripts copied to `~/scripts/devnel-backup/`, checksums match `main`. Restore-test MySQL user with grants on the scratch DB only (`USE` on production denied). Both defaults files and the site config are mode 600. rclone installed from the Ubuntu archive; `devnel-drive` (drive.file scope, trash bypassed) and `devnel-crypt` remotes created by Kyle; `rclone.conf` mode 600; round-trip test passed.
- **Step 7:** manual `db` and `files` runs succeeded: the dump's line 1 is `-- MySQL dump`, a wp-content archive and the nginx config copy were written, off-site copies exist, the marker was written, and no heartbeat warnings appear in the log. `ps` during the dump showed `--defaults-extra-file=…` and no password.
- **Step 7b:** a forced failure (`DB_NAME='nonexistent_db'`) exited 2 with nothing written; the config was restored afterwards. Kyle confirmed on 2026-10-16 that both the alert email and the healthchecks.io `/fail` arrived.
- **Step 8:** the first restore test's import pushed MySQL memory far enough that the OOM killer killed production `mysqld`, which was down for about a minute (devnel-ops known problem 8). Kyle added swap. Reruns under an external memory watchdog passed for both local and `--offsite` dumps: table count, published count and `siteurl` matched production, MySQL didn't restart, and the scratch DB was dropped.
- **Step 9a** (Kyle approved): the legacy devnel.blog crontab line was replaced by the daily DB and weekly files lines; the other site's line is unchanged; the crontab backup is on Triton. **Step 9b (restore-test lines) was held** until `restore-test.sh` guarded memory itself (done in #5; see below).
- **2026-10-16, step 9b** (Kyle approved): the guarded `restore-test.sh` and `lib.sh` were copied to Triton and their checksums match `main`. A manual run passed: start and lowest headroom were logged, well above the floor, and MySQL didn't restart. Kyle checked the crontab diff before it was installed: the weekly (Monday 04:00) and monthly off-site (first Monday 04:30) restore-test lines were added, and a stale comment from 9a was removed. Nothing else changed. The first scheduled runs are 2026-10-19 (local) and 2026-11-02 (off-site).
- **2026-10-16:** the first scheduled DB run (03:15) succeeded: dump, off-site copy, local and off-site pruning, marker.
- **2026-10-16, cleanup phase 1** (Kyle approved): the dry run was checked again, then 62 legacy files were deleted. The newest legacy pair is kept, so the directory is well under 1 GB and disk usage dropped accordingly. Phase 2 is due around **2026-10-29**.

## Follow-ups
- UpdraftPlus isn't the off-site mechanism (decision above). Decide whether to deactivate/remove it in issue 15.

### Follow-ups added by the implementation (issue 18)
- **Pending, needs wp-env (issue 02):** run `docs/runbooks/restore.md` section 3A once from the off-site copy and fill in its "Rehearsal log". The wp-env commands there are marked *(verify)*.
- **Pending, human-gated on Triton:** everything in `docs/runbooks/backup-install.md`; then tick the Triton acceptance criteria (manual run, `restore-test.sh` counts, "no password in `ps`", config files mode 600 on the server, disk usage after `docs/runbooks/backup-cleanup.md`).
- Heartbeats are per job (`HEARTBEAT_URL_DB`, `HEARTBEAT_URL_FILES`, `RESTORE_HEARTBEAT_URL`) so a missing weekly files run is noticed, rather than the single `HEARTBEAT_URL` the deliverable describes.
- New backups go to `~/devnel.blog/backups-v2/` so they never mix with the legacy backlog that the cleanup runbook deletes.
- Optional hardening: back up with a dedicated read-only MySQL user instead of the site's own DB user.
- Issues 13 and 16 read `~/devnel.blog/backups-v2/last-success` (keys `db_time`, `db_file`, `db_sha256`, `files_*`).
- Nit (review round 1, left as is): the install runbook's credentials checks (`SHOW GRANTS` / `USE` flags) could be tightened.
- (review r2 nit) `docs/runbooks/backup-install.md`: `host=$(wp config get DB_HOST)` breaks for `localhost:/path.sock` or `host:port`; option files need separate `socket=`/`port=` lines. The verify step right after catches it.
- (review r2 nit) Restore test fails loudly, not silently, if a scheduled post goes live between the dump and the test (`RESTORE_POSTS_TOLERANCE=0`), or if the DB ever gains triggers/views with a `DEFINER` (the restricted user lacks `SET_USER_ID`).
- (review r3 nit) `deploy/cron/backup.cron`: the monthly off-site restore test uses `flock -n` on the weekly test's lock, so if the 04:00 run overruns it skips with no alert, and the shared `RESTORE_HEARTBEAT_URL` stays green. Give it its own heartbeat or `flock -w`.
- (review r3 nit) `restore-test.sh --offsite` downloads into `${TMPDIR:-/tmp}` (same filesystem as `/`) with no free-space check before the download.
- (review r3 nit) `backup-install.md` step 9: the `~/crontab.before-backups-*` glob breaks if the step is rerun on another day; the quoted legacy cron line has one space before `>/dev/null` where the real one has two (the `grep -vF` pattern is unaffected).
- (install) Restore-test memory guard: built on `issue/18-restore-memory-guard` (three review rounds). `RESTORE_MIN_MEM_MB` pre-check, `RESTORE_ABORT_MEM_MB` import watchdog, signal handling. Merged in #5.
- (install) When mysqldump fails, `backup.sh` reports `command failed: gzip -c > $tmp`. It names the last stage of the pipeline, not the stage that failed. Report the failing stage (`PIPESTATUS`), or say "dump pipeline failed" and point to the log's mysqldump stderr.
- (install, issue 15) The published count the restore test compares covers every post type, and it's far larger than the site's posts and pages. Most of it is probably items the Friends plugin has stored. It's why the dump is so large. Look at it in housekeeping.
- (install) Cleanup phase 2 around 2026-10-29, after two weeks of new backups and at least two weekly restore-test passes. Weekly restore tests run from 2026-10-19, so two passes are due by 2026-10-26.
- (install) The wp-env restore rehearsal still waits for issue 02.
- (memory guard, review r3 nit) Signal windows of one statement each: between `( … ) &` and `IMPORT_PID=$!`, and at the top of `on_exit` before signals are ignored. A signal exactly there skips killing the import, which then fails once the scratch DB is dropped under it.
- (memory guard, review r3 nit) `on_exit` signals pids from the watchdog's snapshot, taken up to 5 s earlier, so a recycled pid could in theory be signalled.
- (memory guard, review r3 nit) The TERM and INT/HUP signal tests don't bound elapsed time, so on their own they prove "the import is gone when the script exits" rather than "the import was killed". The second-signal, teardown and escalation tests cover the kill.
- (memory guard, review r2 nit) If the DROP times out (`lock_wait_timeout=60`), only a warning is logged: the alert doesn't say the scratch DB was left behind, and on the success path the run still reports passed. The abort could also `KILL` the import's own connection so server memory is released at once.
