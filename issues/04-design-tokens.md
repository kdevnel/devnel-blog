# 04. Design tokens, fonts, dark mode (`theme.json`)

**Wave:** 1 · **Depends on:** 03 · **Implementer:** **Opus** (foundation every other theme issue builds on) · **Reviewer:** Opus

## Goal
`theme.json` + `style.css` carry the devNel brand: palette with semantic roles, automatic dark mode, fluid type and space scales, the three self-hosted fonts, and an editor locked to the design.

## Context
- Source of truth: `../devnel-com/src/styles/tokens.css` (palette, semantic roles, dark remap, `--step-*`, `--space-*`, `--measure: 68ch`) and `../devnel-com/src/styles/fonts.css`.
- Design direction: `docs/PLAN.md` → "Design direction".
- `theme.json` has no `prefers-color-scheme` support, so presets have to point at CSS custom properties that `style.css` switches.

## Scope
In: `theme.json` settings + top-level styles (body, headings, links, elements), font files, `style.css` variables + dark remap, contrast script wired to the theme.
Out: per-block styles (06), templates (05).

## Deliverables
- `theme/devnel/theme.json`:
  - `settings.color.palette`: semantic slugs (`bg`, `bg-alt`, `text`, `text-muted`, `heading`, `link`, `link-hover`, `accent`, `on-accent`, `rule`, `focus`, `mark`) with `color: var(--devnel-<slug>)`. `custom`, `customGradient`, `gradients`, `duotone`, `defaultPalette`, `defaultGradients` off.
  - `settings.typography`: `fontFamilies` display (Quando), body (Source Sans 3), mono (IBM Plex Mono) with `fontFace` pointing at `file:./assets/fonts/*.woff2`; `fontSizes` mapped to the `--step-*` scale (fluid off, since the clamps are already in the values); `customFontSize` false; `dropCap` false.
  - `settings.spacing.spacingSizes` from `--space-*`; `units` limited; `layout.contentSize` `68ch`, `wideSize` `72rem`.
  - `settings.appearanceTools` false; `border`/`shadow` customisation off.
  - `styles`: body (bg, text, body font, `--step-0`, line-height 1.6), `elements.link` (with sun underline like devnel-com), `elements.heading` (display font, heading colour, 1.2), `h1`–`h4` sizes, `elements.button`, `:focus-visible` outline via `css`.
- `theme/devnel/style.css`: `:root` `--devnel-*` light values (from tokens.css), `@media (prefers-color-scheme: dark)` remap, `color-scheme: light dark`, `prefers-reduced-motion` guard, skip-link styles.
- `theme/devnel/assets/fonts/`: Latin-subset woff2s (Quando 400, Source Sans 3 variable, IBM Plex Mono 400 (and 500 if used)). Copy from `node_modules/@fontsource*` in devnel-com or download from Fontsource; include their OFL licence files.
- `inc/fonts.php`: preloads body and display fonts (`<link rel="preload" as="font" type="font/woff2" crossorigin>`).
- `scripts/contrast.mjs`: reads light values from `style.css`/`theme.json` and dark values from the media query; checks every text/background pair the theme uses.

## Acceptance criteria
- [ ] Front end and editor show the brand colours and fonts; switching the OS to dark mode remaps everything with no reload artefacts.
- [ ] The editor offers only the theme palette, sizes and fonts (no custom pickers).
- [ ] `npm run contrast` passes AA for every pair in both schemes.
- [ ] Exactly 3 font files (4 if Plex 500 is justified) load on a post page; 2 are preloaded; no external font requests.
- [ ] Visual snapshot baselines created for home and single in both schemes (using the skeleton templates).

## Tests required
- e2e: computed `background-color` and `color` of `body` match the tokens in light and dark (`emulateMedia`).
- e2e: font requests ⊆ the self-hosted list; preload links present.
- contrast script in `npm run check`.

## Quality notes
- Performance: fonts are the biggest render cost, so keep to subsets and `font-display: swap`.
- Accessibility: AA contrast in both schemes; focus ring uses `--devnel-focus` and is ≥ 3:1 against both backgrounds.
- Maintenance: tokens defined once; comments in `style.css` point to tokens.css as the origin.

## Team lead
Before briefing, open devnel.com in light and dark to show the implementer the target (screenshots in the brief).

## Review focus
- Presets → variables → dark remap works in the **editor** too (editor iframe gets `style.css` via `add_editor_style`).
- No hard-coded colours outside the variable definitions.
- Font licence files included.

## Human-gated steps
None.

## Follow-ups
