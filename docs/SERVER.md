# Server: Triton and devnel.blog

What scripts, runbooks and agents need to know about production. Re-check anything here before relying on it (commands are at the bottom).

> **The full audit is private.** The other sites on Triton, exact core and plugin versions, disk figures and the numbered **known problems** live in the private repo `kdevnel/devnel-ops`, cloned next to this one at `../devnel-ops` (`SERVER-AUDIT.md`). Read it there; never copy its contents into this repo, which is public. When an issue says "known problem N", it means that file.

## Host

| | |
| --- | --- |
| Host | `triton.devnel.com`, SSH as `kyle` |
| OS | Ubuntu 24.04 LTS |
| Web | nginx, HTTP/2 + HTTP/3, Brotli + gzip |
| PHP | 8.4 FPM |
| DB | MySQL 8.4 |
| Object cache | Redis (`redis-cache` drop-in) |
| Config base | SpinupWP-style "WordPress nginx" setup (`/etc/nginx/global/`) |
| Other sites | Triton hosts other sites (listed in devnel-ops). **Don't touch them.** Scripts are config-driven per site. |

## devnel.blog

| | |
| --- | --- |
| Site root | `/home/kyle/devnel.blog/public` |
| Logs | `/home/kyle/devnel.blog/logs/{access,error}.log` |
| Page cache | `/home/kyle/devnel.blog/cache` (nginx `fastcgi_cache` zone `devnel.blog`, 60 min, stale-while-error) |
| nginx site | `/etc/nginx/sites-available/devnel.blog`; includes `global/server/{defaults,fastcgi-cache,ssl}.conf` |
| Cache bypass | POST, any query string, `/wp-admin/`, `/wp-json/`, feeds, sitemaps, logged-in/commenter cookies |
| TLS | Let's Encrypt |
| WP-Cron | system cron runs `wp cron event run --due-now` every 5 min |
| Permalinks | `/%year%/%monthnum%/%day%/%postname%/` |
| Active theme | twentytwentyfive (with Site Editor customisations in the DB) |

### Plugins

Versions are in devnel-ops. Each plugin that stays is justified here (QUALITY "Maintenance").

| Plugin | Keep? | Notes |
| --- | --- | --- |
| activitypub | Yes | Fediverse; smoke check covers WebFinger + actor |
| friends (+ autoresolve-links, post-collection) | Yes | Blocks used on pages |
| akismet | Yes | Comment spam |
| nginx-cache | Yes | Purges `/home/kyle/devnel.blog/cache`, auto-purge on |
| redis-cache | Yes | Object cache drop-in |
| redirection | Yes | Existing redirects must survive |
| post-smtp | Yes | The updater's alerts send through it |
| updraftplus | Review in issue 15 | Not used for off-site backups (issue 18 decision) |
| worker (+ `0-worker` mu-plugin) | Kyle decides (issue 15) | |
| syntaxhighlighter | **Remove** after issue 13 | Replaced by server-side highlighting |
| amazon-s3-and-cloudfront (inactive) | **Remove** if unused | |

### Block usage (published posts + pages)

paragraph 90 · column 39 · group 31 · heading 24 · spacer 21 · columns 20 · **syntaxhighlighter/code 15** · list-item 14 · list 11 · image 2 · code 2 · **jetpack/subscriptions 2** · **jetpack/contact-form 1** (+ 4 jetpack/field-*) · **jetpack/slideshow 1** · friends/friends-list 1 · friends/follow-me 1 · html 1 · more 1 · block (reusable) 1 · quote 1.
Also: **3 items in classic-editor format**; shortcodes `[jetpack_subscription_form]`, `[jetpackcrm_clientportal]` (Jetpack isn't installed, so these render as raw text or nothing).

## What agents may and may not do

| Read-only (allowed) | Human-gated (write a runbook step, wait for Kyle) |
| --- | --- |
| `wp core version`, `wp plugin list --skip-update-check` and `wp theme list --skip-update-check` (without the flag they refresh the `update_plugins` / `update_themes` transient: a DB write and a request to wordpress.org), `wp option get`, `wp post list`, `wp cron event list`, `wp eval-file -` scripts that only read | `wp core update`, `wp plugin update/install/delete`, `wp theme activate`, `wp option update`, `wp search-replace`, any content migration; `wp core check-update` (it isn't read-only: `wp_version_check()` refreshes the `update_core` transient and calls wordpress.org unless the last check was under a minute ago, and `--force-check` only skips that limit) |
| `cat`/`ls`/`grep` on config and logs | Editing nginx config, `nginx -s reload`, crontab, wp-config.php, mu-plugins |
| `wp db export /tmp/x.sql` then `scp` off and delete it | Deleting backups, restoring a DB |
| `curl -sI https://devnel.blog/...` | Purging the page cache on production (allowed **within** an approved deploy) |

Findings from read-only checks that reveal versions, other sites or unfixed weaknesses go into `../devnel-ops/SERVER-AUDIT.md`, not this file.

## Re-checking these facts

```sh
ssh triton.devnel.com 'cd ~/devnel.blog/public && wp core version && wp plugin list --skip-update-check && wp cron event list --fields=hook,next_run_relative'
curl -s https://api.wordpress.org/core/version-check/1.7/ | jq -r '.offers[0].version'   # latest core, from your machine, not production
ssh triton.devnel.com 'crontab -l; ls ~/devnel.blog/backups | wc -l; du -sh ~/devnel.blog/backups; df -h /'
curl -s -o /dev/null -w "%{http_code}\n" https://devnel.blog/wp-sitemap.xml
```
