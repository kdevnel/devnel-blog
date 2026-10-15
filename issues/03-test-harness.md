# 03. Test harness

**Wave:** 0 · **Depends on:** 01, 02 · **Implementer:** Sonnet · **Reviewer:** Opus

## Goal
Every later issue can add tests straight away: Playwright + axe, PHPUnit, visual snapshots, contrast, Lighthouse, link crawl and Bats, all wired into `npm run check` and CI, running against **fixture content** that mirrors the real block mix.

## Context
- Bars: `docs/QUALITY.md` → "Tests", "Accessibility", "Performance".
- Port from devnel-com: `../devnel-com/playwright.config.ts` (desktop + mobile projects, separate port), `../devnel-com/tests/e2e/a11y.spec.ts` (axe in light and dark), `../devnel-com/scripts/contrast.mjs`, `../devnel-com/scripts/lighthouse.mjs`.
- CI can't use production data (QUALITY "Tests"), so it needs fixtures.

## Scope
In: test configs, helpers, fixture content, ported scripts, CI wiring, a smoke spec for the skeleton theme.
Out: tests for features not built yet (each issue adds its own).

## Deliverables
- `tools/fixtures/import.sh` + `tools/fixtures/content/*.html`: creates via WP-CLI in the **tests** env (8889) a known set: ≥ 12 posts across categories and tags (enough for pagination), one post per block type in SERVER.md's block list (paragraph, heading, lists, quote, image with alt, `core/code` with language classes, columns/group/spacer, separator, html, more), a post with a featured image, a post with 3 threaded comments, a page, a page with Friends/ActivityPub blocks, a classic-editor post, and a post with a long unbroken code line. Idempotent (resets first).
- `playwright.config.ts`: baseURL `http://localhost:8889`, projects desktop + mobile, `globalSetup` runs fixtures.
- `tests/e2e/helpers/axe.ts`: `expectNoAxeViolations(page, { scheme: 'light'|'dark' })` using `emulateMedia({ colorScheme })` and WCAG 2.2 AA tags.
- `tests/e2e/helpers/weight.ts`: collects requests and asserts JS/CSS/font budgets from QUALITY "Performance".
- `tests/e2e/smoke.spec.ts`: home loads, 200, has `<main>`, no PHP notices in the HTML.
- `tests/php/bootstrap.php` + `phpunit.xml.dist` running inside `wp-env run tests-cli` with the WP test suite; a sample test.
- `scripts/contrast.mjs` ported (reads palette from `theme/devnel/theme.json` + dark overrides once 04 exists; until then the devnel-com palette).
- `scripts/lighthouse.mjs` ported: audits `LH_BASE` (default `http://localhost:8889`) and `LH_PAGES`; same thresholds (overridable).
- Link crawl script (`linkinator` or equivalent) for the tests env: internal links only, fails on 4xx/5xx.
- `tests/shell/` Bats setup with a `stubs/` folder (fake `wp`, `curl`, `ssh`, `mysqldump`) and a helper to put them on `PATH`.
- `npm run check` and CI updated: start wp-env in CI, import fixtures, run phpunit, e2e (with axe), contrast, links, Bats. Visual snapshots: `npm run test:visual` (Linux baselines from CI, kept in git).

## Acceptance criteria
- [ ] `npm run check` runs every layer locally against wp-env and passes on the skeleton theme (axe is allowed to report the skeleton's gaps **only** if marked `test.fixme` with a link to issue 05; record it).
- [ ] CI runs the same, with Playwright report and traces uploaded as artifacts on failure.
- [ ] Fixtures import cleanly twice in a row (idempotent) and cover every block in SERVER.md's list.
- [ ] `expectNoAxeViolations` checks both colour schemes.
- [ ] Bats stubs work: a sample test proves a script calls a stubbed `wp` with expected args.

## Tests required
This issue *is* the tests; each helper has at least one spec using it. Prove the axe helper catches a problem by temporarily injecting an `<img>` without `alt` in a test page.

## Quality notes
- Tests: deterministic (no network to prod, fixed dates in fixtures, `TZ=UTC`).
- Maintenance: one command; documented in README.

## Team lead
After merge, write a short "How to add tests" section in `CLAUDE.md` pointing at the helpers.

## Review focus
- The tests env (8889) is used, never dev (8888), so local work never pollutes test results.
- Fixtures really mirror the production block mix (compare to SERVER.md).
- Lighthouse/contrast thresholds aren't loosened from QUALITY.md.

## Human-gated steps
None.

## Follow-ups
