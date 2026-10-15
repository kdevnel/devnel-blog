# 10. Fediverse integration (ActivityPub + Friends)

**Wave:** 1 · **Depends on:** 05 · **Implementer:** Sonnet · **Reviewer:** Opus

## Goal
Everything ActivityPub and Friends show on the front end fits the theme, and the theme doesn't break federation.

## Context
- DECISIONS D10. Blocks in use: `friends/friends-list`, `friends/follow-me` (SERVER.md). ActivityPub adds: author profile/actor, follow-me block, "reactions" (likes/boosts) and federated replies, and WebFinger at `/.well-known/webfinger`.
- Use the real plugin output in wp-env (02/03 fixtures) to style it, not guesses.

## Scope
In: styles for those plugin blocks/templates, footer Fediverse handle (05 placeholder), author archive layout showing the Fediverse profile, checks that federation endpoints still work with the theme active.
Out: plugin settings, Friends' own admin/feed reader UI.

## Deliverables
- `styles/plugins/activitypub.css`, `styles/plugins/friends.css`, enqueued only when their blocks are on the page (`wp_enqueue_block_style` per block name) — or `theme.json` `styles.blocks` entries where that's enough.
- Dequeue plugin CSS that conflicts with the theme, only if the replacement covers it (document each).
- Author archive: name, bio, Fediverse handle `@handle@devnel.blog` with copy-friendly text, post list.
- Footer handle from 05 wired to the real ActivityPub user setting (via a small `devnel_fediverse_handle()` helper with a fallback).

## Acceptance criteria
- [ ] Pages using `friends/follow-me` and `friends/friends-list`, and the ActivityPub follow-me/reactions blocks, match the theme in both schemes and pass axe.
- [ ] `curl -H 'Accept: application/activity+json'` on the author URL and `/.well-known/webfinger?resource=acct:…` return valid JSON in wp-env with the theme active.
- [ ] Plugin CSS loads only where its blocks are used.
- [ ] Footer shows the correct handle.

## Tests required
- e2e: plugin blocks page visual snapshot + axe (both schemes).
- e2e or PHPUnit: WebFinger and actor JSON respond with 200 and expected `type`.
- PHPUnit: `devnel_fediverse_handle()` with and without the plugin active.

## Quality notes
- Performance: plugin CSS conditional.
- Maintenance: plugin markup changes between versions, so visual snapshots catch drift; the update canary (20) covers this too.

## Team lead
Confirm with Kyle which Fediverse handle should show (blog actor vs author actor).

## Review focus
- Nothing in 07's removals or this issue's dequeues breaks discovery (`<link rel="alternate" type="application/activity+json">` and friends).

## Human-gated steps
None.

## Follow-ups
