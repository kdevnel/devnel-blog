# Runbook: restore devnel.blog from backup

Use this to rehearse a restore in wp-env, to recover a broken production site, or to move the site to a new server. **Restoring onto production is a human-gated step (CLAUDE.md): Kyle approves each write.** Rehearsals in wp-env are safe.

> **Status:** the wp-env rehearsal of this runbook is **pending**: wp-env arrives with issue 02, and acceptance needs one full restore from the off-site copy. Record the date and result under "Rehearsal log" when done. The wp-env commands marked *(verify)* are untested.

## What you need

| Item | Where it lives |
| --- | --- |
| Database dump `YYYYMMDDHHMMSS_database.sql.gz` | `~/devnel.blog/backups-v2/` on Triton, or off-site |
| `YYYYMMDDHHMMSS_files.tar.gz` (wp-content) and `_nginx.conf` | same |
| `last-success` marker (file names + SHA-256 of the newest dump and archive) | `~/devnel.blog/backups-v2/last-success` |
| rclone remotes `devnel-drive` + `devnel-crypt` | Drive token and the **crypt password + salt from the password manager** |
| `wp-config.php` values (DB credentials, salts) | password manager (not in the backups on purpose) |

Dumps contain commenter names, emails and IPs. Never commit them or leave them on shared machines. For a local rehearsal, sanitise afterwards using the issue 02 tooling, and keep the files under `.data/` (gitignored).

## 1. Fetch the backup

From Triton's local copy:

```sh
scp 'triton.devnel.com:devnel.blog/backups-v2/{last-success,*_database.sql.gz,*_files.tar.gz}' .data/restore/
```

Or from off-site, on any machine with rclone configured (`rclone config` with the same Drive token and the same crypt password **and salt**):

```sh
mkdir -p .data/restore && cd .data/restore
rclone lsf devnel-crypt:devnel.blog/db | sort | tail -n 3          # pick the dump
rclone copyto devnel-crypt:devnel.blog/db/<dump>.sql.gz ./<dump>.sql.gz
rclone lsf devnel-crypt:devnel.blog/files | sort | tail -n 3
rclone copyto devnel-crypt:devnel.blog/files/<archive>.tar.gz ./<archive>.tar.gz
rclone copyto devnel-crypt:devnel.blog/nginx/<conf> ./<conf>        # only for a new server
```

## 2. Verify before touching anything

```sh
gzip -t <dump>.sql.gz && gzip -dc <dump>.sql.gz | sed -n 1p        # must start with: -- MySQL dump
gzip -dc <dump>.sql.gz | tail -n 1                                  # must start with: -- Dump completed
gzip -t <archive>.tar.gz && tar -tzf <archive>.tar.gz >/dev/null
shasum -a 256 <dump>.sql.gz                                         # compare with last-success (only the newest file is listed there)
```

If a check fails, use the previous dump. Never load a dump that fails these checks.

## 3A. Restore into wp-env (rehearsal / local copy)

```sh
npm run env:start
# WordPress core is already in the container, so only DB and wp-content are restored.
gzip -dc .data/restore/<dump>.sql.gz > .data/restore/dump.sql
npx wp-env run cli -- wp db reset --yes                              # (verify) wipes the local DB only
docker cp .data/restore/dump.sql "$(docker ps -qf name=cli | head -n1)":/tmp/dump.sql   # (verify) container name
npx wp-env run cli -- wp db import /tmp/dump.sql                     # (verify)
npx wp-env run cli -- wp search-replace 'https://devnel.blog' 'http://localhost:8888' --all-tables --skip-columns=guid
mkdir -p .data/restore/files && tar -xzf .data/restore/<archive>.tar.gz -C .data/restore/files
# copy uploads (and, if needed, plugins) into the container's wp-content            (verify)
npx wp-env run cli -- wp cache flush
npx wp-env run cli -- wp option get siteurl
```

Then check section 5.

## 3B. Restore onto production (disaster or new server) — human-gated

Do each numbered step only after Kyle approves it. The site is down or broken, so take the time to be careful.

1. **Snapshot what's there first** (if the server is reachable): `cd ~/devnel.blog/public && wp db export ~/pre-restore-$(date +%F-%H%M).sql` and keep it until the restore is confirmed good.
2. **Core.** On a new server, install nginx, PHP 8.4-FPM, MySQL 8.4, wp-cli, then:
   ```sh
   cd ~/devnel.blog/public
   wp core download --version=<version that was running> --skip-content
   ```
   On the existing server with intact core, skip this. If core files are damaged, use `wp core download --force --skip-content --version=<same version>` (leaves wp-content and wp-config alone).
3. **wp-config.php.** On a new server create it with the credentials from the password manager (`wp config create --dbname=… --dbuser=… --prompt=dbpass`), then add the salts and the settings the site had.
4. **Database.** Create the database and user if needed, then:
   ```sh
   gzip -dc <dump>.sql.gz | mysql --defaults-extra-file=$HOME/.config/devnel-backup/devnel.blog.my.cnf "$(wp config get DB_NAME)"
   ```
   The dump drops and recreates each table, so it overwrites the existing ones. (`DB_NAME` is not a secret; the password stays in the defaults file.)
5. **wp-content.**
   ```sh
   tar -xzf <archive>.tar.gz -C ~/devnel.blog/public        # restores wp-content/ (uploads, themes, plugins, mu-plugins)
   ```
   Extracting over an existing wp-content leaves any file the archive doesn't contain. **For a compromised or badly broken site, don't extract over it:** move the old one aside first (`mv wp-content wp-content.old`, or at least `rm -rf wp-content/plugins wp-content/themes wp-content/mu-plugins`) so leftover or planted files don't survive, then extract, and delete `wp-content.old` once the site is confirmed good.
   Ownership must be the site user (`ls -l`); fix with `chown -R` as needed.
6. **nginx** (new server only): copy `<conf>` to `/etc/nginx/sites-available/devnel.blog`, symlink into `sites-enabled`, `sudo nginx -t && sudo nginx -s reload`, and re-issue the TLS certificate.
7. **Flush caches:** `wp cache flush`; purge the nginx page cache (`wp nginx-helper`/nginx-cache purge, or empty `~/devnel.blog/cache`); `wp rewrite flush`.
8. **Re-install the backup system** (`docs/runbooks/backup-install.md`) if the server is new.

## 4. Restoring only a file or a table

- One upload: `tar -xzf <archive>.tar.gz -C /tmp/x wp-content/uploads/2026/10/photo.jpg` then copy it into place.
- One table: extract it from the dump with `gzip -dc <dump> | sed -n '/^-- Table structure for table `wp_posts`/{p;:a;n;/^-- Table structure for table /q;p;ba}'` (from that table's header up to the next table's header; mysqldump writes tables alphabetically, so the next one isn't necessarily `wp_postmeta`) into a file, review it, and load it into a **scratch** database first.

## 5. Check the restored site

```sh
wp option get siteurl
wp post list --post_status=publish --format=count
wp plugin list --status=active
curl -sI https://devnel.blog/ | head -n 1
curl -sI https://devnel.blog/<a-known-post-url>/ | head -n 1
```

Open the home page, a post with a code block and an image, the admin, and `/.well-known/webfinger?resource=acct:…` (Fediverse). Compare the published-post count with the number in the last `restore test passed` log line (`~/devnel.blog/logs/backup.log`).

## Rehearsal log

| Date | Source (local/off-site) | Environment | Result | By |
| --- | --- | --- | --- | --- |
| _pending_ | off-site | wp-env | not yet run (needs issue 02) | |
