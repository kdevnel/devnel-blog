# 05. Templates & template parts

**Wave:** 1 · **Depends on:** 04 · **Implementer:** Sonnet · **Reviewer:** Opus

## Goal
All front-end templates exist, are accessible, and match the design direction: a calm reading layout with the devNel mark.

## Context
- Design: `docs/PLAN.md` → "Design direction".
- Mark: the `[>·<]` bowtie from `../devnel-com/src/components/brand/BrandSprite.astro` / `Mark.astro` (SVG paths) and `../devnel-com/src/assets/brand/`.
- Accessibility bars: `docs/QUALITY.md` → "Accessibility".

## Scope
In: `parts/header.html`, `parts/footer.html`, `parts/post-meta.html`, templates `index`, `home`, `single`, `page`, `archive`, `search`, `404`; a `devnel/mark` render (pattern or a tiny dynamic block in `inc/blocks.php`) outputting the inline SVG with `currentColor` and `aria-hidden` + text alternative; navigation menu.
Out: comments markup (09), SEO head tags (11), block-level styling (06).

## Deliverables
- **Header:** skip link (first focusable) → mark + "devNel blog" wordmark (link home, Quando) → `core/navigation` (Home, Topics/categories, About page, RSS) with `aria-label="Main"`, the overlay menu on mobile with a keyboard-accessible toggle (core navigation's own).
- **Footer:** "Part of devnel.com" link, RSS link, Fediverse handle (from the ActivityPub author), copyright year; optional thin slash-pattern strip as a CSS background (decorative, `aria-hidden`).
- **home/index:** `core/query` list, each item: `<time>` in mono, title in Quando (h2, link), one-line excerpt; pagination with labels; no featured images in the list.
- **single:** title (h1), meta (date, reading time optional, categories), featured image (if any, LCP), content at `contentSize`, tags, prev/next post navigation (labelled), comments placeholder for 09.
- **page:** title + content.
- **archive:** archive title ("Posts tagged …"), description, same list as home.
- **search:** search form with visible label, results list, empty state with suggestions.
- **404:** bowtie mark, message, search form, link home.
- An HTML marker comment or `<meta name="generator" content="devnel-theme <version>">` the safe updater (19) can look for. Agree the exact string in this issue and record it in SERVER.md.

## Acceptance criteria
- [ ] Every template renders fixture content without PHP notices and without "invalid block" warnings when opened in the Site Editor.
- [ ] axe passes (light + dark) on home, single, page, category archive, tag archive, search (results + empty), 404; remove any `test.fixme` left by 03.
- [ ] Keyboard: skip link works; nav (including the mobile overlay) usable with keyboard only; focus visible throughout.
- [ ] One `<h1>` per page; post lists use `<ul>`/`<li>`; dates are `<time datetime>`.
- [ ] Theme marker present in every front-end HTML response.
- [ ] Visual snapshots updated for home, single, archive, 404 in both schemes; mobile + desktop.

## Tests required
- e2e per template: renders, landmarks present, h1 count = 1, expected elements (dates, pagination, prev/next).
- e2e keyboard: tab order starts with the skip link; mobile nav opens/closes with Enter/Escape.
- axe on every template in both schemes.

## Quality notes
- Performance: no images in lists; nav uses core block, no extra JS beyond what core navigation needs on mobile (record its size).
- SEO: semantic headings; archive titles meaningful.

## Team lead
Have Kyle confirm the nav items and footer contents (or use the defaults above) before briefing.

## Review focus
- Block markup round-trips (open each template in the Site Editor in wp-env and check for "attempt recovery").
- Mark SVG accessible (decorative SVG hidden, text name provided once).
- No hard-coded colours or font sizes; only presets.

## Human-gated steps
None.

## Follow-ups
