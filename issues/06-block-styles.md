# 06. Block styles & editor parity

**Wave:** 1 · **Depends on:** 04 · **Implementer:** Sonnet · **Reviewer:** Opus

## Goal
Every block the blog actually uses looks right on the front end and the same in the editor, and the editor offers nothing that breaks the design.

## Context
- Blocks in use: `docs/SERVER.md` → "Block usage".
- Tokens from 04 only.

## Scope
In: `theme.json` `styles.blocks` for paragraph, heading, list, quote, image (+ caption), code (base box only; colours in 08), preformatted, group, columns/column, spacer, separator, buttons, table, details; `styles/blocks/*.css` loaded per block via `wp_enqueue_block_style` where `theme.json` isn't enough; editor styles; curating patterns and block styles.
Out: syntax colours (08), comments (09), Fediverse blocks (10).

## Deliverables
- Block styles in `theme.json`; per-block CSS files only where needed (each loaded only when that block is on the page).
- `inc/editor.php`: `add_theme_support('editor-styles')` + `add_editor_style('style.css')`; remove core patterns (`remove_theme_support('core-block-patterns')`), stop remote pattern loading (`should_load_remote_block_patterns` false); unregister block styles that don't fit (e.g. `core/image` "rounded", `core/quote` "plain" if unused, `core/button` "outline" if unused).
- `patterns/`: 1–3 curated patterns (e.g. "Note/aside" callout, "TIL" intro). Keep them minimal.
- Spacer: the blog has 21 spacers. Style them to map onto the space scale so existing content doesn't look broken before 13 cleans it up.
- Columns: stack below a sensible breakpoint; gap from the space scale.
- Code block: focusable scroll container (`tabindex="0"` via `render_block` filter, with an accessible name) — coordinate with 08, which owns the inner markup.

## Acceptance criteria
- [ ] The fixture post for each block type looks correct in light + dark (visual snapshots added per block group).
- [ ] Editor and front end match for those blocks (manual check, recorded with screenshots in the PR).
- [ ] No core or remote patterns offered; only the curated ones.
- [ ] Block CSS loads only on pages using the block (verified on home vs a post with columns).
- [ ] axe passes on the per-block fixture posts in both schemes.

## Tests required
- Visual snapshots for the block fixture posts.
- e2e: home page doesn't load columns/quote CSS; the columns post does.
- e2e: code block scroll container is focusable and named.

## Quality notes
- Accessibility: quote citation styling distinguishable without colour alone; captions meet contrast.
- Performance: keep to the CSS budget in QUALITY.md; measure after.

## Team lead
Point the implementer at the fixture posts from 03 and the real pages in the local dev env (from 02) that use columns heavily.

## Review focus
- No `!important` wars with core; specificity kept low (`:where()` where possible).
- Editor styles really apply inside the iframe editor.

## Human-gated steps
None.

## Follow-ups
