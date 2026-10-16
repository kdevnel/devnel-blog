# Instructions for agents

This repo is the devnel.blog WordPress block theme and its operations tooling. Read this file first, every time.

## How work happens

- Work is split into issues in `issues/`. **Work on one issue at a time, on its own branch** (`issue/NN-slug`), in a git worktree.
- The process (team lead → implementer → independent reviewer) is in `docs/WORKFLOW.md`. Follow it; don't skip the review.
- Each issue lists its dependencies. Don't start one until those are merged; check `issues/README.md` for status.
- An issue's acceptance criteria are the contract. Something the issue doesn't mention is out of scope: note it in the issue's "Follow-ups" section; don't build it.
- Every change has to meet `docs/QUALITY.md`. If an issue conflicts with QUALITY.md, stop and ask the lead.

## Guardrails (non-negotiable)

1. **Production is read-only for agents.** You may SSH to `triton.devnel.com` and run read-only commands (`wp … list|get|check-update`, with `wp plugin list` and `wp theme list` always given `--skip-update-check`, because without it they refresh an update transient (a write, plus a request to wordpress.org), `cat`, `ls`, `curl -I`, `wp db export` to a temp file you then copy off and delete). Anything that **writes** to production (DB changes, files, nginx, crontab, plugin or core updates, theme activation, deleting backups) is a **human-gated step**: write it as a runbook command and wait for Kyle to approve it. Approving one step doesn't approve the next.
2. **No secrets in git, and nothing from the private audit.** This repo is public: never copy other site names, exact production versions, disk figures or unfixed weaknesses into it; reference `../devnel-ops` instead. No passwords, API keys, DB dumps or `.env` files. DB snapshots live in `.data/` (gitignored) and **must be sanitised** (see issue 02) before they're used anywhere but your machine.
3. **No third-party requests at runtime** from the theme: no CDNs, no Google Fonts, no analytics. Everything self-hosted.
4. **Always back up before migrating.** Content migrations (`tools/`) default to dry-run and must be run against a local copy before production.
5. **Don't edit WordPress core or plugin files.** Customise through the theme, `theme.json`, filters, or a small mu-plugin from this repo.

## Conventions

- **PHP:** WordPress Coding Standards (`phpcs`), PHPStan level 6 with WordPress stubs, PHP 8.4. Escape everything on output (`esc_html`, `esc_attr`, `esc_url`, `wp_kses_post`). Prefix functions and hooks with `devnel_`. One concern per file in `theme/devnel/inc/`.
- **CSS:** plain CSS, no preprocessor or bundler. Tokens come from `theme.json` presets and the `--devnel-*` custom properties in `style.css`. Logical properties, `:focus-visible`, `prefers-reduced-motion`.
- **JS:** none on the front end unless an issue explicitly allows it.
- **Block markup** in templates and patterns has to round-trip in the Site Editor without "invalid block" warnings.
- **Shell scripts:** `bash`, `set -euo pipefail`, `shellcheck`-clean, Bats tests in `tests/shell/`.
- **Tests sit with the code they test.** Every issue lists the tests it has to add.
- **Commits:** imperative mood, reference the issue (`#NN`). Keep the CHANGELOG up to date for user-visible changes.

## Commands (once issue 01 lands)

```sh
npm ci && composer install
npm run env:start        # wp-env on http://localhost:8888 (tests on :8889)
npm run db:pull          # sanitised production snapshot into wp-env (issue 02)
npm run check            # everything CI runs: lint, phpcs, phpstan, stylelint, phpunit, e2e, axe, contrast, bats
npm run lighthouse       # Lighthouse against LH_BASE (default the wp-env URL)
```

## Key facts

- Production: `https://devnel.blog`, server `triton.devnel.com`, site root `/home/kyle/devnel.blog/public`. Details in `docs/SERVER.md`; the full private audit (other sites, versions, known problems) is in `../devnel-ops/SERVER-AUDIT.md`.
- Permalinks: `/%year%/%monthnum%/%day%/%postname%/`. **Never change them.**
- Brand source: the sibling repo `../devnel-com` (tokens in `src/styles/tokens.css`, logo SVGs in `src/assets/brand/`).
