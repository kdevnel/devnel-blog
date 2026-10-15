# 12. Security hardening

**Wave:** 2 · **Depends on:** 05 · **Implementer:** **Opus** (security-critical, easy to break wp-admin or federation) · **Reviewer:** Opus

## Goal
The theme is provably safe (escaping, no stored input), and the site sends modern security headers and closes common WordPress leaks, without breaking wp-admin, the block editor, ActivityPub, Akismet or the remote-management plugin (`worker`).

## Context
- Bars: `docs/QUALITY.md` → "Security". Current state: devnel-ops known problem 6.
- WordPress needs `style-src 'unsafe-inline'` (inline global styles, block supports); scripts in wp-admin also use inline code, so the CSP is front-end-only or a looser admin policy.

## Scope
In: escaping audit of `theme/devnel`, `inc/security.php`, `deploy/nginx/security-headers.conf`, wp-config recommendations, a CSP report endpoint plan.
Out: server firewall/SSH hardening (separate, Kyle's), plugin code.

## Deliverables
- **Theme audit:** phpcs `WordPress.Security.*` passes with no blanket ignores; a short audit note in the PR listing every output point checked.
- `inc/security.php`:
  - Block anonymous REST user enumeration (`/wp/v2/users` requires auth) **without** breaking ActivityPub (it uses its own routes; verify).
  - Redirect `?author=N` enumeration for anonymous users to the author archive slug or 404 (careful: ActivityPub author URLs must keep working).
  - Remove the WP version from head and feeds; `X-Pingback` removed.
  - Disable XML-RPC (`xmlrpc_enabled` false) **after confirming** the `worker` plugin doesn't need it (it uses its own endpoint; check docs and test in wp-env). If anything needs it, restrict to required methods and record why.
- `deploy/nginx/security-headers.conf` (included in the devnel.blog server block, **front-end locations only**; wp-admin gets the non-CSP headers):
  - `Content-Security-Policy-Report-Only` first: `default-src 'self'; img-src 'self' data: https:; style-src 'self' 'unsafe-inline'; script-src 'self'; font-src 'self'; connect-src 'self'; frame-ancestors 'self'; base-uri 'self'; form-action 'self'; object-src 'none'` (adjust for embeds actually used; `img-src https:` because federated avatars come from other servers), plus `report-to`/`report-uri`.
  - `Strict-Transport-Security: max-age=31536000; includeSubDomains` (start with `max-age=86400`, raise after a week; **no** `preload` without Kyle's say-so).
  - `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy: camera=(), microphone=(), geolocation=(), interest-cohort=()`, `X-Content-Type-Options: nosniff` (already), `X-Frame-Options` kept as fallback.
  - Deny `xmlrpc.php` at nginx (if disabled above), deny `wp-config.php` backups, `.env`, `readme.html`, `license.txt`.
  - Watch out for nginx `add_header` inheritance: headers in a `location` replace those from `server`. Document how the snippet avoids losing the existing ones.
- CSP reports: simplest option is a tiny mu-plugin REST route that logs to a file with rate limiting, or a free external collector **only if Kyle approves** (it's a third party). Default: log to `~/devnel.blog/logs/csp.log`.
- `deploy/wp-config-hardening.md`: `DISALLOW_FILE_EDIT`, `WP_AUTO_UPDATE_CORE false` (coordinated with 19), `FORCE_SSL_ADMIN`, salts rotated if old.
- Enforcement plan: after 7 days of clean reports, switch to enforcing `Content-Security-Policy` (runbook step).

## Acceptance criteria
- [ ] phpcs security sniffs clean; audit note in PR.
- [ ] In wp-env behind a local nginx with the snippet (docker-compose in `deploy/test/`): front end, wp-admin, block editor, Site Editor, comment posting, ActivityPub WebFinger/actor all work; browser console shows no CSP violations on the front end for fixture pages.
- [ ] `/wp-json/wp/v2/users` → 401 for anonymous; author archives and ActivityPub author URLs still 200.
- [ ] `curl -I` on front-end and admin URLs shows the intended headers, and the existing ones (`X-Content-Type-Options`, `Fastcgi-Cache`, `Alt-Svc`) are still there.
- [ ] Rollout runbook (report-only → enforce, HSTS ramp) written.

## Tests required
- PHPUnit: REST users route protected; `?author=` handling; XML-RPC disabled filter; version removed.
- e2e (against the nginx test container): header assertions; zero CSP violation events on fixture pages (`page.on('console')` + `securitypolicyviolation` listener).
- Bats/curl test for nginx deny rules.

## Quality notes
- Maintenance: the snippet lives in git; production is updated only by copying it (runbook) and nginx -t first.

## Team lead
1. Confirm with Kyle: `worker` still in use? Any embeds (YouTube etc.) expected in posts? CSP report destination?
2. Schedule the report-only → enforce switch as a follow-up after launch.

## Review focus
- `add_header` inheritance mistakes that silently drop headers.
- CSP breaking the block editor (it's served from wp-admin; make sure the strict policy doesn't apply there).
- Anything that blocks ActivityPub federation (author URLs, WebFinger, inbox POSTs).

## Human-gated steps
1. Install `security-headers.conf` on Triton, `sudo nginx -t`, reload.
2. wp-config changes.
3. Enforcing CSP and raising HSTS max-age after the observation window.

## Follow-ups
