# 13. Content migration scripts

**Wave:** 2 · **Depends on:** 06, 08 · **Implementer:** **Opus** (mutates production content) · **Reviewer:** Opus

## Goal
Clean, current block content: SyntaxHighlighter blocks become `core/code`, dead Jetpack blocks and shortcodes are gone or replaced, classic-editor posts are converted, and layout-heavy pages are listed for Kyle to review. All done with safe, repeatable scripts.

## Context
- Inventory: `docs/SERVER.md` → "Block usage" (15 `syntaxhighlighter/code`; `jetpack/subscriptions` ×2, `jetpack/contact-form` + 4 fields, `jetpack/slideshow` ×1; shortcodes `[jetpack_subscription_form]`, `[jetpackcrm_clientportal]`; 3 classic items; 20 columns / 21 spacers).
- Guardrail: CLAUDE.md #4 (dry run first, local first, backup before prod).

## Scope
In: `tools/migrate/*.php` (run with `wp eval-file`), a runner script, reports, tests.
Out: redesigning pages by hand (Kyle does that from the report), removing the SyntaxHighlighter plugin (16).

## Deliverables
- `tools/migrate/run.sh <env> [--apply]`: runs every migration in order; **dry run by default**; `--apply` requires a fresh backup marker file (path from issue 18) newer than 1 hour when the env is production.
- `tools/migrate/01-syntaxhighlighter-to-code.php`: parse with `parse_blocks`, map `syntaxhighlighter/code` attrs (`language`, `content`, `highlightLines`, `firstLineNumber`, `title`) to `core/code` with `className: language-<x>` (map SyntaxHighlighter brush names to the 08 library's names: `jscript`→`javascript`, `plain`→none, etc.); drop unsupported attributes but list them in the report. Re-serialise with `serialize_blocks`.
- `02-jetpack-cleanup.php`: `jetpack/subscriptions` → a paragraph linking to the RSS feed and the Fediverse handle (or remove; Kyle chooses); `jetpack/contact-form` → paragraph linking to https://devnel.com/contact/; `jetpack/slideshow` → `core/gallery` with the same image IDs; strip the two shortcodes (replace the subscription one like the block, remove the CRM portal one).
- `03-classic-to-blocks.php`: wraps classic content via `core/freeform` → convert to proper blocks using the same transform the editor uses (server-side: `parse_blocks` on raw HTML is not enough; acceptable approach is splitting on block-level HTML into `core/paragraph`/`heading`/`list`/`image`/`html` blocks; anything unsure stays `core/html` and is listed).
- `04-layout-report.php` (read-only): lists posts/pages with columns/group/spacer, with counts and edit links, to `reports/layout-review.md`.
- Every write: saves via `wp_update_post` (creates a revision, so each change can be undone in the editor), skips posts whose content is unchanged (idempotent), and logs post ID + before/after hashes.
- Report: `reports/migration-<env>-<timestamp>.md` with per-post diffs (unified diff of the block markup).

## Acceptance criteria
- [ ] On a fresh sanitised production copy (02): dry run lists every expected change; `--apply` makes them; a second `--apply` changes nothing.
- [ ] After apply: zero `syntaxhighlighter/code`, `jetpack/*` blocks or the two shortcodes remain (verified by the block-count query from SERVER.md).
- [ ] Every converted post opens in the block editor in wp-env with **no** "This block contains unexpected or invalid content" warnings (e2e opens each changed post in the editor).
- [ ] Converted code blocks render highlighted (08) with the correct language.
- [ ] Revisions exist for each changed post.
- [ ] Production run refuses without a recent backup marker.

## Tests required
- PHPUnit: each transform on fixture block strings (attribute mapping, brush mapping, nested blocks inside columns/groups, idempotency, malformed input untouched).
- e2e: editor validity check on all changed posts in the tests env after running migrations on fixtures.
- Bats: `run.sh` refuses `--apply` on production without the marker; default is dry run.

## Quality notes
- Maintenance: scripts stay in the repo as a record of what was done; reports committed (no PII in them, only post IDs, titles and markup).

## Team lead
1. Ask Kyle for the replacement choices (subscriptions → RSS/Fediverse text or remove; contact form → link).
2. Run on a fresh local copy, share the dry-run report with Kyle, get approval.

## Review focus
- Nested blocks (code inside columns/groups) handled.
- `serialize_blocks` round-trip doesn't alter untouched blocks (compare hashes of unchanged posts).
- No path where `--apply` hits production without the backup check.

## Human-gated steps
1. Production dry run (read-only); Kyle reviews the report.
2. Production apply (part of the launch runbook, 16), right after a verified backup.

## Follow-ups
