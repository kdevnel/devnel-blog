# 20. Update canary in CI

**Wave:** R · **Depends on:** 03, 05 · **Implementer:** Sonnet · **Reviewer:** Opus

## Goal
Before a major WordPress or plugin version reaches production, it's already been run in CI against the theme and realistic content, and the safe updater (19) can check that result.

## Context
- 19 applies gated updates only when `canary.json` approves the exact version and it has soaked ≥ 3 days.
- Fixture content from 03 covers the production block mix; 13 adds fixtures for converted content.
- Production plugin list: `docs/SERVER.md` → "Plugins" (only the ones that stay).

## Scope
In: `.github/workflows/canary.yml`, `.wp-env.canary.json` (or env overrides), the canary.json publisher, failure issue creation.
Out: deciding the policy (19 owns it).

## Deliverables
- `.github/workflows/canary.yml`: daily at 02:00 UTC + manual. Steps:
  1. Resolve latest versions: WordPress (`https://api.wordpress.org/core/version-check/1.7/`), each plugin (`https://api.wordpress.org/plugins/info/1.2/?action=plugin_information&slug=…`), including release dates.
  2. Start wp-env with those exact versions + the theme from `main` + fixtures.
  3. Run `npm run check` parts that apply (PHPUnit, e2e incl. axe and visual snapshots, link crawl) **plus** `smoke.sh` against wp-env and a PHP error-log scan.
  4. Write `canary.json`: `{ "generated": ISO, "commit": sha, "wordpress": {"version","released","result"}, "plugins": [{"slug","version","released","result"}], "overall": "pass|fail", "run_url" }`. Per-item `result` lets one bad plugin fail without blocking the others: if the full run fails, re-run with that plugin pinned to the production version to isolate it (bounded to 3 bisection runs).
  5. Publish `canary.json` to the `canary` branch (force-push a single commit) so it's at a stable raw URL; keep the last 30 in `history/`.
  6. On failure: open or update a GitHub issue "Canary failing: <item> <version>" with the run link; close it when green.
- JSON schema `config/canary.schema.json` (used by 19 to validate).
- README section explaining the canary.

## Acceptance criteria
- [ ] Workflow runs green on `main` with the current latest versions (or correctly reports a real failure).
- [ ] `canary.json` validates against the schema and is reachable at the raw URL 19 will use.
- [ ] Forced failure (a branch run with a deliberately broken fixture or a plugin pinned to a known-bad build) produces a per-item `fail`, an issue, and no false pass for the other items.
- [ ] Workflow permissions: `contents: write` only for the publishing job; actions SHA-pinned.

## Tests required
- Unit test (node) for the version resolver and the canary.json writer against recorded API responses.
- Schema validation test.

## Quality notes
- Security: the canary repo branch is the trust root for majors. Branch protection on `canary` (only the workflow's token can push); 19 validates the schema and only accepts versions that exist on wordpress.org.
- Maintenance: the plugin list in the workflow comes from one file (`config/plugins.json`) shared with `.wp-env.json` generation, so the two stay in sync.

## Team lead
Needs the GitHub remote (01). If there isn't one, the canary can run on Triton in a container. Discuss with Kyle; the GitHub option is preferred.

## Review focus
- Isolation logic can't mark a broken version as `pass`.
- Visual snapshot diffs from plugin markup changes are reported, not auto-updated.

## Human-gated steps
None (CI only).

## Follow-ups
