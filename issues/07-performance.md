# 07. Performance layer

**Wave:** 1 · **Depends on:** 05 · **Implementer:** Sonnet · **Reviewer:** Opus (regressions for admin/plugins)

## Goal
Logged-out pages ship only what they use, so the theme meets the QUALITY.md performance budgets, without breaking wp-admin, logged-in editing or the plugins.

## Context
- Budgets: `docs/QUALITY.md` → "Performance".
- Page caching already exists on the server (DECISIONS D3); this issue is about payload size and render path.

## Scope
In: `theme/devnel/inc/performance.php` and its tests.
Out: server config (12), image CDN (not used).

## Deliverables
`inc/performance.php`, each change guarded so it applies **only** on the front end for logged-out requests unless noted:
- Remove emoji detection script and styles; oEmbed discovery links and `wp-embed`; RSD and WLW manifest links; shortlink; REST API `<link>` in head (keep the header for ActivityPub discovery if needed; verify).
- Dequeue `dashicons` and `admin-bar` for logged-out users; never enqueue jQuery on the front end.
- `should_load_separate_core_block_assets` → true; `wp_should_load_block_assets_on_demand` if available.
- Global styles: don't output the SVG duotone filters; keep the global styles CSS inline (it's small) and check its size.
- `comment-reply` enqueued only on singular views with open comments, threading on, and a comment form present.
- Images: `fetchpriority="high"` + no lazy on the featured image in `single`; `sizes` that match the 68ch column; register an image size for the content column if needed.
- Speculation rules: keep core's default (WP 6.8+ conservative prefetch); document it.
- Disable the Heartbeat API on the front end.

## Acceptance criteria
- [ ] QUALITY.md budgets met on the fixture single post: 0 KB theme/core JS for logged-out users (except `comment-reply` where required), CSS ≤ 30 KB, ≤ 3 fonts.
- [ ] Lighthouse (wp-env) ≥ 95 performance, 100 on the rest, for home, single, archive, search, 404.
- [ ] Logged-in: admin bar, block editor, Site Editor, and comment moderation work (e2e logs in and checks).
- [ ] ActivityPub WebFinger and actor endpoints still respond correctly (e2e or PHPUnit).

## Tests required
- PHPUnit: each filter/action is registered only on front-end, logged-out contexts (and not in admin or REST).
- e2e weight check (helper from 03) on home and single.
- e2e logged-in: admin bar visible, editor loads without console errors.
- Lighthouse run recorded in the PR.

## Quality notes
- Maintenance: every removal has a one-line comment explaining why; group by concern.

## Team lead
Run Lighthouse before and after and put both numbers in the PR.

## Review focus
- Any removal that runs in admin, REST, feeds or for logged-in users.
- ActivityPub depends on some head links/REST discovery. Make sure none of it was removed.

## Human-gated steps
None.

## Follow-ups
