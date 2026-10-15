# 01. Repo scaffold & tooling

**Wave:** 0 · **Depends on:** — · **Implementer:** Sonnet (standard tooling, well specified) · **Reviewer:** Opus

## Goal
A repo where `npm ci && composer install && npm run check` works, CI runs the same checks, and an empty `devnel` theme activates in WordPress.

## Context
- Target layout: `README.md` → "Repo layout".
- Copy the CI pattern from `../devnel-com/.github/workflows/ci.yml`: actions pinned to commit SHAs, `permissions: contents: read`, Node from `.nvmrc`.
- No front-end build step (DECISIONS D2, QUALITY "Maintenance").

## Scope
In: git init, package.json, composer.json, linters, CI, Dependabot, theme skeleton, `.gitignore`.
Out: wp-env setup (02), test suites (03), any design (04+).

## Deliverables
- `package.json` with scripts: `lint` (eslint for tests/scripts, stylelint, prettier --check), `lint:php` (phpcs), `analyse` (phpstan), `check` (runs everything; later issues add to it). Dev deps: `@wordpress/env`, `@playwright/test`, `@axe-core/playwright`, `stylelint` + `stylelint-config-standard`, `prettier`, `eslint`, `bats`, `shellcheck` (or document as a system dependency).
- `composer.json` (dev): `wp-coding-standards/wpcs`, `phpcompatibility/phpcompatibility-wp`, `phpstan/phpstan`, `szepeviktor/phpstan-wordpress`, `dealerdirect/phpcodesniffer-composer-installer`.
- `phpcs.xml.dist` (WordPress ruleset, text domain `devnel`, prefix `devnel`, `testVersion 8.4-`), `phpstan.neon.dist` (level 6, paths `theme/devnel/inc`).
- `.editorconfig`, `.nvmrc` (22), `.prettierrc`, `.stylelintrc.json`, `.gitignore` (`node_modules`, `vendor`, `.data/`, `test-results/`, `playwright-report/`, `.env`, `*.sql*`).
- `theme/devnel/style.css` (theme header: Theme Name devNel, Requires at least 6.9, Tested up to 6.9, Requires PHP 8.4, Version 0.1.0, License MIT, Text Domain devnel), `theme.json` (`version: 3`, empty settings), `templates/index.html` (minimal valid block markup), `functions.php` (loads `inc/*.php`), `inc/.gitkeep`.
- `.github/workflows/ci.yml`, `.github/dependabot.yml` (npm, composer, github-actions; weekly).
- `CHANGELOG.md` (Keep a Changelog format), `LICENSE` (MIT).

## Acceptance criteria
- [x] Fresh clone: `npm ci && composer install && npm run check` passes.
- [x] CI workflow runs on PR and push to `main`, SHA-pinned actions, read-only permissions, and runs `npm run check` plus `composer audit` and `npm audit --omit=dev`.
- [x] phpcs and phpstan run against `theme/devnel` and pass on the skeleton.
- [ ] The theme zip (`theme/devnel/`) passes Theme Check's required checks (run in 02/03 once wp-env exists; note it in Follow-ups if 02 isn't done yet).
- [x] `.gitignore` covers DB snapshots and secrets.

## Tests required
None beyond the linters running green. Add a deliberate phpcs violation locally, confirm `npm run check` fails, then remove it (record this in the report).

## Quality notes
- Maintenance: pin exact versions in lockfiles; Dependabot on.
- Security: CI tokens read-only; no secrets needed.

## Team lead
1. Create the repo in this folder (`git init`, first commit of the existing docs **before** the implementer starts).
2. Ask Kyle whether to create the GitHub remote now (needed for CI, 17 and 20). If not, record that CI runs locally until then.
3. Brief the implementer and review as usual.

## Review focus
- Actions pinned by SHA, not tag; `permissions` minimal.
- `npm run check` really fails on violations (not `|| true`).
- Theme header values match QUALITY "Maintenance".

## Human-gated steps
Creating the GitHub repo (Kyle).

## Follow-ups

- Theme Check (acceptance criterion 4) could not be verified: wp-env doesn't exist until issue 02. Run Theme Check's required checks against `theme/devnel/` in 02/03.
- The GitHub remote (`kdevnel/devnel-blog`, public) was created during this issue; first CI run on GitHub green on 2026-10-15 (run 38757220162). `main` protected the same day. Action SHAs were looked up with `gh api` (checkout v7.0.1, setup-node v7.1.0, setup-php 2.40.0).
- phpstan `paths` lists `theme/devnel/functions.php` as well as `inc/`: PHPStan errors on an empty path set, and `inc/` has no PHP yet. Drop it once `inc/` has code if desired.
- The npm `shellcheck` package downloads its binary on first run (needs network).
- (review nit) `scripts/check-shell.sh` only shellchecks `*.sh`/`*.bash`; an extensionless script would be skipped silently. Either detect bash shebangs or make the `.sh` extension a CLAUDE.md convention.
- (review nit) Theme Check will likely want `theme/devnel/screenshot.png` and `readme.txt`; add them when 02/03 run Theme Check.
- CI uses `ubuntu-latest`, which moves to Ubuntu 26 from 2026-10-19. Consider pinning `ubuntu-24.04` to match Triton.
