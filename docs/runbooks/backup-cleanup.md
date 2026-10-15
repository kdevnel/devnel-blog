# Runbook: clean up the legacy backups (issue 18)

**Deleting backups is a human-gated step. Kyle approves each phase.** This only touches `~/devnel.blog/backups/` (the old, legacy directory). It never touches `~/devnel.blog/backups-v2/` (the new backups) or any other site's backup directory.

Why: the legacy script's retention never matched anything, so the old directory has grown without bound and takes a large share of the disk. The legacy dumps also have a warning as line 1 (`mysqldump: [Warning] Using a password…`), so a plain restore of them fails; and the old tarballs contain the whole of `public/`, including `wp-config.php`. They are worth deleting once the new system is proven.

## Preconditions: do not start phase 1 until all are true

Check on Triton (all read-only):

```sh
cat ~/devnel.blog/backups-v2/last-success          # db_time and files_time recent
ls -l ~/devnel.blog/backups-v2 | tail
rclone ls devnel-crypt:devnel.blog                 # off-site copies exist
grep 'restore test passed' ~/devnel.blog/logs/backup.log | tail -n 3     # local AND --offsite runs passed
crontab -l | grep -n 'devnel-backup'               # the new entries are installed; the legacy devnel.blog line is gone
```

## Phase 1: after the first verified new backup (and restore test)

Keep the newest legacy database dump and the newest legacy files archive as a fallback. Delete the rest.

```sh
cd ~/devnel.blog/backups
ls | wc -l; du -sh .

KEEP_DB="$(ls *_database.sql.gz | sort | tail -n 1)"
KEEP_FILES="$(ls *_files.tar.gz | sort | tail -n 1)"
echo "keeping: $KEEP_DB $KEEP_FILES"

# Dry run: the list of files that WILL be deleted. Read it.
find . -maxdepth 1 -type f \( -name '*_database.sql.gz' -o -name '*_files.tar.gz' \) \
  ! -name "$KEEP_DB" ! -name "$KEEP_FILES" -print | sort | less

# Anything else in the directory is not touched by the command below; look at it:
find . -maxdepth 1 -type f ! -name '*_database.sql.gz' ! -name '*_files.tar.gz' -print
```

Once the list is right and Kyle approves:

```sh
find . -maxdepth 1 -type f \( -name '*_database.sql.gz' -o -name '*_files.tar.gz' \) \
  ! -name "$KEEP_DB" ! -name "$KEEP_FILES" -delete
ls; du -sh .; df -h /
```

Acceptance: the directory is under 1 GB (two files remain) and `df -h /` shows the disk usage dropped by about the old directory's size.

## Phase 2: after the new system has two weeks of history

Confirm first:

```sh
ls ~/devnel.blog/backups-v2/*_database.sql.gz | wc -l       # about 14 daily dumps
ls ~/devnel.blog/backups-v2/*_files.tar.gz | wc -l          # at least 2 weekly archives
grep 'restore test passed' ~/devnel.blog/logs/backup.log | wc -l    # at least 2 weekly passes
```

Healthchecks has been green for the whole period, with no unacknowledged failure emails. Then, with Kyle's approval:

```sh
rm -i ~/devnel.blog/backups/*_database.sql.gz ~/devnel.blog/backups/*_files.tar.gz
rmdir ~/devnel.blog/backups      # fails if anything unexpected is left, which is what you want
df -h /
```

## Rollback

There isn't one for a deleted file, which is why phase 1 keeps the newest pair and why phase 2 waits two weeks. If a legacy dump is ever needed, strip the warning line first: `gzip -dc <dump> | sed 1d | mysql …`.
