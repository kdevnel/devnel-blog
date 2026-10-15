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
- [ ] On Triton (human-gated install): a manual run produces a dump whose first line is `-- MySQL dump`, a wp-content archive, an off-site copy, and a heartbeat ping.
- [ ] `restore-test.sh` passes against that dump on Triton and reports counts matching production.
- [ ] A full restore into wp-env from the off-site copy works, following `docs/runbooks/restore.md`.
- [x] Retention deletes old files (Bats with fake timestamps) and the disk check aborts when space is low.
- [ ] No password in `ps` output or in the script; config files mode 600.
- [ ] After cleanup, `~/devnel.blog/backups` is under 1 GB and disk usage drops accordingly.

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
