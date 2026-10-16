# Issues

One file per issue. The team lead keeps the **Status** column current (`todo` → `in progress` → `review` → `done`; `blocked` with a reason). Process: `docs/WORKFLOW.md`. Dependency graph: `docs/PLAN.md`.

**Start here:** 18 (it fixes a live production risk) and 01 can run in parallel right away.

| # | Issue | Wave | Depends on | Implementer | Reviewer | Human-gated | Status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 01 | [Repo scaffold & tooling](01-repo-scaffold.md) | 0 | — | Sonnet | Opus | — | done |
| 02 | [Local environment mirroring production](02-local-environment.md) | 0 | 01 | Sonnet | Opus | — | done |
| 03 | [Test harness](03-test-harness.md) | 0 | 01, 02 | Sonnet | Opus | — | todo |
| 04 | [Design tokens, fonts, dark mode](04-design-tokens.md) | 1 | 03 | **Opus** | Opus | — | todo |
| 05 | [Templates & template parts](05-templates.md) | 1 | 04 | Sonnet | Opus | — | todo |
| 06 | [Block styles & editor parity](06-block-styles.md) | 1 | 04 | Sonnet | Opus | — | todo |
| 07 | [Performance layer](07-performance.md) | 1 | 05 | Sonnet | Opus | — | todo |
| 08 | [Server-side syntax highlighting](08-syntax-highlighting.md) | 1 | 04 | Sonnet | Opus | — | todo |
| 09 | [Comments](09-comments.md) | 1 | 05 | Sonnet | Opus | — | todo |
| 10 | [Fediverse integration](10-fediverse.md) | 1 | 05 | Sonnet | Opus | — | todo |
| 11 | [SEO](11-seo.md) | 2 | 05 | Sonnet | Opus | nginx sitemap fix | todo |
| 12 | [Security hardening](12-security.md) | 2 | 05 | **Opus** | Opus | nginx + wp-config | todo |
| 13 | [Content migration scripts](13-content-migration.md) | 2 | 06, 08 | **Opus** | Opus | run on prod | todo |
| 14 | [Deploy pipeline](14-deploy.md) | 3 | 01 | Sonnet | Opus | first deploy | todo |
| 15 | [Pre-launch housekeeping](15-prelaunch-housekeeping.md) | 3 | 19 | Haiku | Sonnet | all of it | todo |
| 16 | [Launch](16-launch.md) | 3 | 07, 09–15, 18, 19 | Lead | Opus | all of it | todo |
| 17 | [Ongoing maintenance automation](17-maintenance-automation.md) | 3 | 16 | Sonnet | Opus | — | todo |
| 18 | [Reliable backups](18-backups.md) | R | — | Sonnet | Opus | cron + cleanup | in progress (running on Triton; cleanup phase 2 and wp-env rehearsal pending) |
| 19 | [Safe auto-updater](19-safe-updater.md) | R | 18 (20 for majors) | **Opus** | Opus | cron, mu-plugin, first run | todo |
| 20 | [Update canary in CI](20-update-canary.md) | R | 03, 05 | Sonnet | Opus | — | todo |

## Pending human-gated steps

_The lead adds each one here with its issue number and the exact commands while it waits for Kyle._

- **#18:** `docs/runbooks/backup-cleanup.md` phase 2 around 2026-10-29, after two weekly restore-test passes (2026-10-19 and 2026-10-26).
- **#18:** the wp-env restore rehearsal in `docs/runbooks/restore.md` 3A (unblocked: 02 is done; local only, not human-gated).

## Issue template

```markdown
# NN. Title

**Wave:** · **Depends on:** · **Implementer:** model (why) · **Reviewer:** model

## Goal
## Context
## Scope
In: … / Out: …
## Deliverables
## Acceptance criteria
- [ ] …
## Tests required
## Quality notes
## Team lead
## Review focus
## Human-gated steps
## Follow-ups
```
