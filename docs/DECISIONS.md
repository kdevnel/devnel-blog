# Decisions

Short records of choices already made, so agents don't revisit them. To change one, add a new entry that supersedes it.

## D1. A WordPress block theme, not a headless frontend (2026-10-15)

An Astro frontend over WPGraphQL was considered. It was rejected because it would need a build pipeline, publish webhooks, a second deployment and its own versions of previews, comments and plugin output. A block theme keeps one system, instant publishing, and everything the plugins already do. The costs: a looser CSP (`style-src 'unsafe-inline'`) and performance that depends on removing WordPress's default assets.

## D2. Built from scratch, not a child theme (2026-10-15)

A minimal block theme is about 10 files. Starting from Twenty Twenty-Five would mean overriding its styles and removing its fonts, variations and patterns. The Create Block Theme plugin may be used in wp-env to scaffold and export, never on production.

## D3. No APO or paid CDN (2026-10-15)

Triton already caches whole pages with nginx FastCGI and purges on publish (Nginx Cache plugin), and Redis provides the object cache. Cached pages are static HTML served by nginx. Edge caching only helps distant readers, which isn't worth paying for on a small blog. If that ever changes, the free Cloudflare proxy with static-asset caching comes first.

## D4. Stay on Triton (2026-10-15)

Kyle's own SpinupWP-style setup (nginx 1.28, PHP 8.4 FPM, MySQL 8.4, Redis, Ubuntu 24.04). No move to managed hosting.

## D5. Block Editor stays (2026-10-15)

Kyle is happy writing in it. Editor customisation is locked down in `theme.json`, so content stays within the design.

## D6. Code highlighting on the server (2026-10-15)

SyntaxHighlighter Evolved highlights in the browser with JS. It's being replaced by a `render_block` filter on `core/code` that outputs highlighted HTML, which then gets page-cached. That means no JS for readers. The 15 existing `syntaxhighlighter/code` blocks are converted by issue 13.

## D7. No SEO plugin (2026-10-15)

A single-author blog needs a meta description, OG tags, JSON-LD and a working sitemap. About 150 lines of tested PHP in `inc/seo.php` is less to maintain than an SEO plugin and its settings.

## D8. Keep comments (2026-10-15)

Comments stay open (2 approved so far), Akismet is already active, and the FastCGI cache already bypasses commenters. The theme provides accessible comment templates. Revisit if spam becomes work.

## D9. One updater owns updates (2026-10-15)

Native background updates are turned off, and `scripts/safe-update.sh` (issue 19) does all core and plugin updates: one at a time, with smoke checks and rollback after each, majors gated by the CI canary (issue 20). Having two update systems makes failures hard to trace.

## D10. Fediverse plugins stay (2026-10-15)

ActivityPub and Friends are active and in use. The theme supports their front-end output, and the updater's smoke check covers WebFinger and the ActivityPub actor.
