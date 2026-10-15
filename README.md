# devnel-blog

A custom WordPress block theme for [devnel.blog](https://devnel.blog), plus the tooling that keeps the blog safe, fast and up to date: tests, deploys, backups, auto-updates and their checks.

The blog stays on WordPress, with the Block Editor, on Kyle's own server (Triton). The theme is a simpler take on the devNel brand from [devnel.com](https://devnel.com): one reading column, the same palette and fonts, and dark mode that follows the system setting.

> **Status:** scaffold built (issue 01); the rest is in progress. See [`issues/README.md`](issues/README.md).

## Where to start

| You are… | Read |
| --- | --- |
| Any agent, before doing anything | [`CLAUDE.md`](CLAUDE.md) |
| The team lead picking the next issue | [`issues/README.md`](issues/README.md), then [`docs/WORKFLOW.md`](docs/WORKFLOW.md) |
| Working on an issue | The issue file, [`docs/QUALITY.md`](docs/QUALITY.md), and [`docs/SERVER.md`](docs/SERVER.md) if it touches production |
| Wanting the big picture | [`docs/PLAN.md`](docs/PLAN.md), [`docs/DECISIONS.md`](docs/DECISIONS.md) |

## Repo layout (once built)

```
theme/devnel/          The block theme (theme.json, templates, parts, patterns, inc/, assets/)
tools/                 WP-CLI scripts: content migration, fixtures
scripts/               Contrast, Lighthouse, DB pull, deploy, safe-update, backup
deploy/nginx/          nginx snippets (security headers, sitemap fix), applied by hand
deploy/cron/           Crontab entries for Triton, applied by hand
tests/e2e/             Playwright + axe
tests/php/             PHPUnit (run inside wp-env)
tests/shell/           Bats tests for the server scripts
.github/workflows/     CI, update canary, scheduled production checks
docs/                  Plan, workflow, quality bars, server notes, decisions
issues/                The work, one file per issue
```

## Getting started

Requirements: Node 22 (`.nvmrc`), PHP 8.4 and Composer 2. `shellcheck` and `bats` are npm dev
dependencies (no system install needed). The `shellcheck` npm package downloads its binary from
GitHub on first use, so the first `npm run test:shell` needs network access. If that is a problem,
install both system-wide instead (`brew install shellcheck bats-core`); `npm run check` fails with
a clear message if either is missing.

```sh
npm ci && composer install
npm run check     # lint (eslint, stylelint, prettier), phpcs, phpstan, shellcheck, bats
```

CI (`.github/workflows/ci.yml`) runs the same `npm run check`, plus `composer audit` and
`npm audit --omit=dev`. Until the GitHub remote exists, `npm run check` is the gate.
