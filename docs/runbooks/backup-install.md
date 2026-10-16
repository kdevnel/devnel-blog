# Runbook: install the devnel.blog backups on Triton (issue 18)

**Every step here writes to production. Kyle runs them (or approves each one); approving one step doesn't approve the next.** Agents may only run the read-only checks.

The new scripts are separate from the legacy `~/scripts/backup.sh`, which another site on Triton still uses. **Don't edit, move or delete `~/scripts/backup.sh`.** Only the devnel.blog crontab line is replaced (step 9).

Credentials never go through an agent or git: the MySQL passwords are generated on Triton, and the Google Drive token and the crypt passwords are created by Kyle in `rclone config`.

Layout after install:

| What | Where |
| --- | --- |
| Scripts | `~/scripts/devnel-backup/{backup.sh,restore-test.sh,lib.sh}` |
| Site config (mode 600) | `~/.config/devnel-backup/devnel.blog.env` |
| MySQL defaults files (mode 600) | `~/.config/devnel-backup/devnel.blog.my.cnf`, `devnel.blog.restore.my.cnf` |
| Backups | `~/devnel.blog/backups-v2/` (a new directory, so the old backlog and the new backups don't mix) |
| Logs | `~/devnel.blog/logs/backup.log`, `backup-cron.log` |
| rclone config (mode 600) | `~/.config/rclone/rclone.conf` |

`wp-config.php` is **not** backed up (it holds secrets). Keep a copy in the password manager; the restore runbook needs it.

## 0. Before you start (read-only, safe for agents)

```sh
ssh triton.devnel.com 'crontab -l | grep -n backup; which rclone mysqldump wp flock; df -h /; ls ~/.config'
ssh triton.devnel.com 'cd ~/devnel.blog/public && wp config get DB_NAME && wp config get DB_USER'
```

## 1. Healthchecks (hosted elsewhere, not on Triton)

In your self-hosted Healthchecks create three checks and copy their ping URLs:

Use the **Cron** schedule type with the time zone set to Triton's (`timedatectl show -p Timezone --value`; `Africa/Johannesburg` at install). With UTC every check fires early and alerts as late.

| Check | Cron expression | Grace |
| --- | --- | --- |
| devnel.blog backup db | `15 3 * * *` | 2 hours |
| devnel.blog backup files | `30 3 * * 0` | 6 hours |
| devnel.blog restore test | `0 4 * * 1` | 6 hours |

The monthly off-site restore test (04:30, first Monday) pings the restore-test check too; an extra success ping is harmless.

Add the email/notification integration you want. Keep the URLs for step 4.

## 2. Create the config directory and install the scripts

From a checkout of the reviewed, merged `scripts/backup/` on your machine:

```sh
ssh triton.devnel.com 'umask 077 && mkdir -p ~/.config/devnel-backup && mkdir -p ~/scripts/devnel-backup ~/devnel.blog/backups-v2 && chmod 700 ~/devnel.blog/backups-v2'
scp scripts/backup/backup.sh scripts/backup/restore-test.sh scripts/backup/lib.sh triton.devnel.com:scripts/devnel-backup/
ssh triton.devnel.com 'chmod 755 ~/scripts/devnel-backup/*.sh && ls -l ~/scripts/devnel-backup'
```

## 3. MySQL: a restore-test user with rights on the scratch database only, and the defaults files

On Triton (`ssh triton.devnel.com`). Passwords are generated here and written straight to mode-600 files; they never appear in `ps` (shell built-ins only) or in git.

```sh
umask 077
cd ~/devnel.blog/public
DB_NAME="$(wp config get DB_NAME)"
SCRATCH="${DB_NAME}_restoretest"
SCRATCH_ESC="${SCRATCH//_/\\_}"       # underscores are wildcards in GRANT, escape them
RT_USER="${DB_NAME}_rt"               # MySQL user names are limited to 32 chars; shorten if needed
RT_PW="$(openssl rand -hex 24)Aa1-"   # the suffix satisfies MySQL's validate_password policy (upper, digit, special); avoid '!' (bash history expansion)

# Triton's MySQL root uses password auth (not auth_socket), and there is no /etc/mysql/debian.cnf,
# so `sudo mysql` is refused. Log in as root with its password; the prompt reads from the terminal.
mysql -u root -p <<SQL
CREATE USER '${RT_USER}'@'localhost' IDENTIFIED BY '${RT_PW}';
GRANT ALL PRIVILEGES ON \`${SCRATCH_ESC}\`.* TO '${RT_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

printf '[client]\nuser=%s\npassword="%s"\nhost=localhost\n' "$RT_USER" "$RT_PW" > ~/.config/devnel-backup/devnel.blog.restore.my.cnf
unset RT_PW

# Backup credentials: reuse the site's DB user, written without printing it.
printf '[client]\nuser=%s\npassword="%s"\nhost=%s\n' \
  "$(wp config get DB_USER)" \
  "$(wp config get DB_PASSWORD | sed 's/\\/\\\\/g; s/"/\\"/g')" \
  "$(wp config get DB_HOST)" > ~/.config/devnel-backup/devnel.blog.my.cnf

chmod 600 ~/.config/devnel-backup/*.my.cnf
ls -l ~/.config/devnel-backup
```

Verify the restore user is boxed in (the first must list only the scratch database, the second **must fail** with "Access denied"):

```sh
mysql --defaults-extra-file=$HOME/.config/devnel-backup/devnel.blog.restore.my.cnf -e 'SHOW GRANTS'
mysql --defaults-extra-file=$HOME/.config/devnel-backup/devnel.blog.restore.my.cnf -e "USE \`$DB_NAME\`"
```

Verify the backup defaults file works without a password on the command line (should print `-- MySQL dump`):

```sh
mysqldump --defaults-extra-file=$HOME/.config/devnel-backup/devnel.blog.my.cnf --no-data --no-tablespaces "$DB_NAME" | head -n 1
```

(`restore-test.sh` refuses to run if the restore user can `USE` the production database, so a mistake here fails closed.)

## 4. Site config

```sh
umask 077
cp /dev/null ~/.config/devnel-backup/devnel.blog.env     # then paste deploy/backup/devnel.blog.env.example
$EDITOR ~/.config/devnel-backup/devnel.blog.env
chmod 600 ~/.config/devnel-backup/devnel.blog.env
```

Fill in `HEARTBEAT_URL_DB`, `HEARTBEAT_URL_FILES`, `RESTORE_HEARTBEAT_URL` (step 1) and `ALERT_EMAIL` if you don't want the site's admin email. Leave `OFFSITE_REMOTE` empty until step 6 is done. Check the paths in `deploy/backup/devnel.blog.env.example` still match (`BACKUP_DIR` is `~/devnel.blog/backups-v2`).

## 5. rclone (install if missing)

Skip this step if `which rclone` already prints a path.

```sh
sudo apt update && sudo apt install rclone     # Ubuntu's package is older but supports drive and crypt
rclone version
```

If you prefer the current upstream release, download the `.deb` from the rclone releases page, verify its SHA256 against the published `SHA256SUMS`, and `sudo dpkg -i` it. Don't pipe an install script into `sudo bash`.

## 6. rclone: Google Drive + crypt (Kyle only, never through an agent)

1. **On a machine with a browser** (your laptop, with rclone installed): `rclone authorize "drive" "<client_id>" "<client_secret>"` (use your own OAuth client ID so you aren't sharing rclone's rate limit; scope `drive.file`, so rclone only sees files it created). Copy the token it prints.
   - **Set the OAuth consent screen's publishing status to "In production"** (Google Cloud console, APIs & Services, OAuth consent screen) *before* authorising. In "Testing" status Google expires refresh tokens after 7 days, and every off-site copy would then fail. The `drive.file` scope is non-sensitive, so moving to production doesn't need Google verification.
2. **On Triton:** `rclone config`
   1. `n` (new remote), name `devnel-drive`, storage `drive`.
   2. Client ID/secret as above, scope `drive.file`, leave root folder empty.
   3. Advanced config: `y`; set **`use_trash` = `false`** (so pruned dumps don't keep using quota). Leave the rest.
   4. Use web browser to authenticate: **`n`**, then paste the token from step 1.
   5. `n` (new remote), name `devnel-crypt`, storage `crypt`, remote `devnel-drive:devnel-backups`, filename encryption `standard`, directory name encryption `true`.
   6. Password and salt: choose "generate" (`g`, 1024 bits) for both. **Copy both passwords into the password manager now.** Without them the off-site copies can't be read, and the Drive token alone isn't enough to read them.
3. `chmod 600 ~/.config/rclone/rclone.conf`. This file holds the Drive token and the crypt passwords (obscured, not encrypted), so anyone who can read it can read the off-site backups. Treat it like the DB credentials.
4. Test (creates and removes one small file):
   ```sh
   echo "ok $(date -u +%FT%TZ)" | rclone rcat devnel-crypt:devnel.blog/test.txt
   rclone cat devnel-crypt:devnel.blog/test.txt
   rclone lsf -R devnel-drive:devnel-backups   # directory and file names should look like gibberish (crypt encrypts both)
   rclone delete --drive-use-trash=false devnel-crypt:devnel.blog/test.txt
   ```
5. Set `OFFSITE_REMOTE='devnel-crypt:devnel.blog'` in `~/.config/devnel-backup/devnel.blog.env`.

## 7. First manual run

```sh
~/scripts/devnel-backup/backup.sh devnel.blog db
~/scripts/devnel-backup/backup.sh devnel.blog files
```

Check:

```sh
ls -lh ~/devnel.blog/backups-v2
cat ~/devnel.blog/backups-v2/last-success
gzip -dc ~/devnel.blog/backups-v2/*_database.sql.gz | head -n 1     # -- MySQL dump ...
tar -tzf ~/devnel.blog/backups-v2/*_files.tar.gz | head
rclone ls devnel-crypt:devnel.blog
tail -n 30 ~/devnel.blog/logs/backup.log
```

To check that no password is visible in the process list, open a **second shell** on Triton and run this *while the DB backup is running* (the dump is short, so launch it in the first shell and run this immediately):

```sh
ps -eo args | grep '[m]ysqldump'      # shows --defaults-extra-file=... and no password
```

Healthchecks should show a start and a success for both checks, and the log shouldn't contain a secret.

Also prove alerting once: in Healthchecks, trigger a failure on one check (or pause and let it miss) and confirm the notification reaches you. The email path (`wp eval wp_mail`) is exercised by a real failure; to test it safely run `~/scripts/devnel-backup/backup.sh devnel.blog db` after temporarily setting `DB_NAME='nonexistent_db'` in the site config (mysqldump fails, nothing is written, an email and a `/fail` ping go out), then remove that line.

## 8. First restore test

**Check memory first.** Importing the dump raises MySQL's memory use for the length of the import. On a small server with no swap this can make the kernel OOM killer kill the *production* `mysqld` (it happened on the first install; see `../devnel-ops`, known problem 8). Before running:

```sh
free -m          # the swap line must not be 0; if it is, add swap first (a human-gated step)
```

During the first run, watch `free -m` from a second shell and stop the test (Ctrl-C; the trap drops the scratch DB) if available memory plus free swap gets low.

```sh
~/scripts/devnel-backup/restore-test.sh devnel.blog
~/scripts/devnel-backup/restore-test.sh devnel.blog --offsite
```

Both must end with `restore test passed` and counts matching production. The scratch database is dropped at the end; confirm with `mysql --defaults-extra-file=$HOME/.config/devnel-backup/devnel.blog.restore.my.cnf -e 'SHOW DATABASES'`.

## 9. Cron: replace only the devnel.blog backup line

Install in two parts, each approved separately: **9a** the backup lines, **9b** the restore-test lines. Don't do 9b until both step 8 runs have passed *and* the installed `restore-test.sh` has the memory guard (`RESTORE_MIN_MEM_MB`); a cron run has nobody watching memory.

### 9a. Backup lines

```sh
BEFORE=~/crontab.before-backups-$(date +%F-%H%M%S)
crontab -l > "$BEFORE"                                     # keep this backup; note the file name
crontab -l | grep -vF 'cd /home/kyle/devnel.blog/public/; /home/kyle/scripts/backup.sh' > ~/crontab.new
# Expect exactly one line fewer than before:
wc -l "$BEFORE" ~/crontab.new
# Append the two backup entries from deploy/cron/backup.cron (daily DB, weekly files), not the restore-test lines:
cat >> ~/crontab.new   # paste them, then Ctrl-D
diff "$BEFORE" ~/crontab.new               # review: one '<' line removed, the new lines added, nothing else
```

The removed line is the legacy devnel.blog entry (`0 5 * * 0 cd /home/kyle/devnel.blog/public/; /home/kyle/scripts/backup.sh  >/dev/null 2>&1`). The other site's `backup.sh` line (cd into a different site) and the WP-Cron lines must show as unchanged. When the diff is right:

```sh
crontab ~/crontab.new && crontab -l
rm ~/crontab.new
```

Rollback: `crontab "$BEFORE"` (the file name printed above).

### 9b. Restore-test lines

First copy the `restore-test.sh` and `lib.sh` that have the memory guard (from `main`) and check them:

```sh
scp scripts/backup/restore-test.sh scripts/backup/lib.sh triton.devnel.com:scripts/devnel-backup/   # from a checkout of main
ssh triton.devnel.com 'cd ~/scripts/devnel-backup && sha256sum restore-test.sh lib.sh && grep -c RESTORE_MIN_MEM_MB restore-test.sh && command -v pgrep'
sha256sum scripts/backup/restore-test.sh scripts/backup/lib.sh   # must match
```

Then run it once by hand (`~/scripts/devnel-backup/restore-test.sh devnel.blog`). It must pass and log `memory headroom: … at start, lowest … during import`.

```sh
BEFORE=~/crontab.before-restoretest-$(date +%F-%H%M%S)
crontab -l > "$BEFORE"
crontab -l > ~/crontab.new
cat >> ~/crontab.new   # paste the two restore-test entries from deploy/cron/backup.cron, then Ctrl-D
diff "$BEFORE" ~/crontab.new               # review: only the two new lines added
crontab ~/crontab.new && crontab -l && rm ~/crontab.new
```

Rollback: `crontab "$BEFORE"`.

## 10. Afterwards

- Next morning: `cat ~/devnel.blog/backups-v2/last-success` shows a fresh `db_time`; Healthchecks is green.
- Don't delete the old `~/devnel.blog/backups/` yet. Follow `docs/runbooks/backup-cleanup.md` after the first verified new backup and again after two weeks.
- The restore procedure is `docs/runbooks/restore.md`.
