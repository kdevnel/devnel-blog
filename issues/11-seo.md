# 11. SEO

**Wave:** 2 · **Depends on:** 05 · **Implementer:** Sonnet · **Reviewer:** Opus

## Goal
Search engines and social sites get correct, complete metadata; no existing URL breaks; the core sitemap works.

## Context
- DECISIONS D7 (no SEO plugin). Bars: `docs/QUALITY.md` → "SEO".
- **Live bug:** `/wp-sitemap.xml` returns 404 because `global/server/static-files.conf` matches `\.xml$` without `try_files` (devnel-ops known problem 4).
- Missing site icon files (devnel-ops known problem 5).

## Scope
In: `inc/seo.php`, OG fallback image, site icon assets, nginx snippet for the sitemap fix, URL inventory scripts.
Out: Search Console setup (Kyle can do this after launch; note it in 16).

## Deliverables
- `inc/seo.php`:
  - `<meta name="description">` from the excerpt (singular) or term/site description; trimmed to ~155 chars, escaped.
  - Open Graph (`og:type` article/website, title, description, url, image + width/height/alt, `article:published_time`/`modified_time`, `og:site_name`) and `twitter:card=summary_large_image`.
  - JSON-LD: `WebSite` on home; `BlogPosting` on posts (headline, description, datePublished, dateModified, image, url, `author` → `Person` {name Kyle Nel, url https://devnel.com, `sameAs` [devnel.com, Fediverse profile, GitHub, LinkedIn from devnel-com's `src/content/site/profile.json`]}); `BreadcrumbList` optional.
  - `noindex,follow` on search results and paginated archives page ≥ 2 (`wp_robots` filter).
  - Remove the users sitemap provider from core sitemaps (it leaks the username).
  - `robots.txt` (`robots_txt` filter) adds the sitemap URL.
- `assets/og-default.png` (1200×630, brand mark + "devNel blog"), generated once. The satori approach in `../devnel-com/integrations/og-images.ts` is fine as a one-off script in `tools/`.
- Site icon: favicon/apple-touch from `../devnel-com/src/assets/brand/favicon.png` / `icon-square-512.png`; set via `wp option update site_icon` in a runbook step (human-gated) or ship static files in the theme and output `<link rel="icon">`; also a real `/favicon.ico` file in the site root (runbook).
- `deploy/nginx/sitemap-fix.conf`: the corrected location (`try_files $uri /index.php$is_args$args;` inside the `\.xml$` block, or a dedicated `location ~ ^/wp-sitemap.*\.xml$` before it). Note it affects every site including `static-files.conf`, so prefer a per-site override in `sites-available/devnel.blog`.
- `scripts/url-inventory.sh`: crawls a base URL (sitemap + internal links) and writes a sorted URL list with status codes; `scripts/url-diff.sh` compares two inventories (used in 16).

## Acceptance criteria
- [ ] In wp-env: `/wp-sitemap.xml` 200, lists posts/pages/categories/tags, no users sitemap.
- [ ] Every singular page has exactly one description, complete OG/Twitter tags, and valid JSON-LD (parsed in tests, checked against required properties).
- [ ] Search and page ≥ 2 archives have `noindex`.
- [ ] Lighthouse SEO 100 on all audited pages.
- [ ] A URL inventory of **production as it is now** is saved to `docs/url-inventory-pre-launch.txt` (read-only crawl).
- [ ] nginx snippet written and tested in a local nginx container or reasoned through in the PR; production change listed as a human-gated step.

## Tests required
- PHPUnit: description fallback chain; JSON-LD structure for a post with and without featured image; robots directives per context; users sitemap removed.
- e2e: head tags present on single/page/home; JSON-LD parses; `wp-sitemap.xml` 200.
- Bats: url-diff reports added/removed/changed status.

## Quality notes
- Security: all head output escaped; JSON-LD via `wp_json_encode` with `JSON_UNESCAPED_SLASHES` and `</script>` safe (`JSON_HEX_TAG`).
- Maintenance: no settings UI; values come from WordPress data.

## Team lead
1. Run the pre-launch URL inventory against production (read-only) once the script exists.
2. Bring the sitemap nginx fix to Kyle. It's worth applying **before** launch, since sitemaps are broken today.

## Review focus
- No duplicate tags with core (canonical, title) or with ActivityPub's own meta.
- JSON-LD escaping.

## Human-gated steps
1. Apply `deploy/nginx/sitemap-fix.conf` to `/etc/nginx/sites-available/devnel.blog`, `sudo nginx -t && sudo systemctl reload nginx`, verify `curl -I https://devnel.blog/wp-sitemap.xml` → 200.
2. Upload `/favicon.ico` to the site root; set the site icon.

## Follow-ups
