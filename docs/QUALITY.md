# Quality bars

Every issue has to meet the sections that apply to it. Reviewers check against this file. Each bar says how it's measured, so "done" can be checked.

## Performance

| Measure | Bar | How it's checked |
| --- | --- | --- |
| Lighthouse mobile, Performance | ≥ 95 on wp-env; ≥ 95 on production after launch | `scripts/lighthouse.mjs` (issue 03), weekly against prod (17) |
| Lighthouse Accessibility / Best Practices / SEO | 100 | same |
| Theme JS on a logged-out post page | 0 KB (`comment-reply` only when threaded comments are open and the post has a comment form) | e2e: count `<script src>` from the theme or core |
| CSS shipped on a post page | ≤ 30 KB uncompressed (theme + block CSS + global styles) | e2e page-weight check |
| Fonts | ≤ 3 woff2 files, Latin subsets, `font-display: swap`; the 2 above-the-fold faces preloaded | e2e checks requests |
| CLS | 0 | Lighthouse |
| LCP image | `fetchpriority="high"`, never `loading="lazy"` | e2e on a post with a featured image |
| Cached TTFB (production) | < 200 ms from Europe | smoke check `curl -w %{time_starttransfer}` |
| Images | responsive `srcset`/`sizes`, width/height set, lazy below the fold | e2e |

Rules: no render-blocking third-party resources; nothing enqueued unless the page uses it; logged-in users and wp-admin keep working.

## Accessibility

- **WCAG 2.2 AA** for every template, in light **and** dark.
- axe (`@axe-core/playwright`, tags `wcag2a, wcag2aa, wcag21aa, wcag22aa`) finds **zero** violations on: home, a single post with code + image + quote + comments, a page, category archive, tag archive, search results, empty search, 404.
- `scripts/contrast.mjs` passes: body text ≥ 4.5:1, large text and UI ≥ 3:1, for every pair in both schemes.
- Keyboard: skip link to `<main>` is the first focusable element; visible `:focus-visible` on everything; no keyboard traps; nav usable without a pointer.
- Structure: `lang` set; one `<h1>` per page; heading levels don't skip; landmarks (`header`, `nav` with label, `main`, `footer`); post lists are lists; dates in `<time datetime>`.
- Motion: everything respects `prefers-reduced-motion`.
- Forms (search, comments): visible labels, errors linked with `aria-describedby`, success and failure announced.
- Code blocks: horizontal scroll container is focusable (`tabindex="0"`) with an accessible name.
- Authors: `docs/MAINTENANCE.md` explains alt text and heading use in the editor.

## Security

- Every PHP output is escaped (`esc_html`, `esc_attr`, `esc_url`, `wp_kses_post`); phpcs `WordPress.Security` sniffs pass with no ignores unless justified in a comment.
- The theme stores no user input and adds no forms, endpoints or options beyond core.
- No runtime requests to third parties from the theme.
- Response headers (issue 12): CSP, HSTS, `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy`, `X-Content-Type-Options`, `frame-ancestors 'self'`. CSP starts as report-only and is enforced only after a clean week.
- `DISALLOW_FILE_EDIT`; `xmlrpc.php` blocked unless something needs it; REST user enumeration closed to anonymous users.
- Server scripts: credentials never on the command line or in git; files with secrets are mode 600; scripts run as `kyle`, not root.
- Dependencies: `composer audit` and `npm audit --omit=dev` clean in CI; Dependabot on.
- Production writes are human-gated (CLAUDE.md).

## Tests

| Layer | Tool | Covers |
| --- | --- | --- |
| PHP unit/integration | PHPUnit in `wp-env run tests-cli` | `inc/` logic: highlighting, SEO output, performance filters, security filters |
| End-to-end | Playwright (desktop + mobile), against wp-env with the fixture content | Every template renders; nav, search, comments, 404; page weight; images |
| Accessibility | axe in Playwright, light + dark | See above |
| Visual | Playwright screenshots (`toHaveScreenshot`) for home, single, archive, 404 in both schemes | Catches unintended design changes |
| Contrast | `scripts/contrast.mjs` | Token pairs |
| Performance | `scripts/lighthouse.mjs` | Lighthouse bars |
| Links | Crawl (e.g. `linkinator`) on wp-env; before/after URL comparison at launch | No broken internal links, old URLs still resolve |
| Shell | Bats with stubbed `wp`, `curl`, `mysqldump` | backup, restore test, safe-update, deploy scripts |
| Static | phpcs (WPCS + PHPCompatibilityWP 8.4), PHPStan L6, stylelint, prettier, shellcheck | |

Rules: new behaviour comes with a test that fails without it. Tests run against **fixture content** (`tools/fixtures/`) that mirrors the real block mix, never a production dump in CI.

## SEO

- Permalink structure unchanged; every URL the old theme served still returns 200 or a 301 to the right place (crawl before launch, crawl after, diff).
- `/wp-sitemap.xml` returns 200 (it's a 404 today; see SERVER.md) and lists posts, pages, categories and tags; no author or user sitemap if that leaks usernames.
- One canonical per page (core); `<title>` from core; meta description from the excerpt.
- Open Graph + Twitter card on every post and page, with an image (featured image or the branded fallback).
- JSON-LD: `BlogPosting` on posts (headline, dates, author → `Person` with `sameAs` devnel.com and the Fediverse profile), `WebSite` on home. Valid against schema.org (checked in tests).
- `noindex` on search results and on paginated archives beyond page 1.
- RSS/Atom feeds kept and linked in `<head>`; `robots.txt` points to the sitemap.

## Maintenance

- **Kept current automatically:** the safe updater (19) applies core minor and plugin patch/minor updates nightly, with smoke checks and per-step rollback; majors apply only after the CI canary (20) passes. Alerts on update, rollback, hold, or a missed heartbeat.
- **Backups** (18): daily DB, weekly files, off-site copy, weekly automated restore test, retention that actually deletes old files, disk-space guard.
- **Simple to change:** no build step beyond Composer; plain CSS; tokens in one place (`theme.json`). Dependencies pinned, with Dependabot.
- **Releases:** semver theme version, CHANGELOG, `Requires at least` / `Tested up to` / `Requires PHP` kept accurate.
- **Few plugins:** each one installed is justified in SERVER.md; unused ones removed.
- **Docs:** `docs/MAINTENANCE.md` (issue 17) covers routine tasks; every issue updates the docs it affects.
