# 09. Comments

**Wave:** 1 · **Depends on:** 05 · **Implementer:** Sonnet · **Reviewer:** Opus

## Goal
Accessible, on-brand comments on posts: threaded list and a comment form that works with Akismet and the page cache.

## Context
- DECISIONS D8 (keep comments). nginx bypasses the cache for `comment_author_*` cookies (SERVER.md), so commenters see their own pending comment.
- ActivityPub may federate replies in as comments; they should render like any other comment.

## Scope
In: `parts/comments.html` (core comment blocks), styles, `comment-reply` behaviour, `inc/comments.php` tweaks.
Out: spam handling beyond Akismet; comment notification emails.

## Deliverables
- Core `comments` block: title with count ("3 responses"), threaded `comment-template` (author, `<time>`, content, reply link), pagination, and `post-comments-form`.
- Form: visible labels for name/email/website/comment; required fields marked in text, not only by colour; the website field may be removed (Kyle's call, default: remove); privacy note; cookie consent checkbox kept.
- Errors: WordPress's default error page for empty fields is poor UX. Add `required` attributes and `aria-describedby` hints so browsers catch it first; keep server-side validation as is.
- Moderation notice after submitting (pending comment visible to the author) is styled and announced (`role="status"`).
- Federated comments (ActivityPub) show the remote author's avatar/name/link correctly.
- Avatars: Gravatar requests are a third-party runtime request. Default: turn avatars off (`show_avatars` stays as-is in options; the theme hides them) **or** use local initials. Decide with Kyle; record in DECISIONS.

## Acceptance criteria
- [ ] Posting a comment in wp-env (logged out) works, shows the moderation notice, and passes axe.
- [ ] Threaded replies render nested with correct heading/list semantics; reply link moves the form with keyboard focus management (core `comment-reply`).
- [ ] No Gravatar requests unless Kyle chose to keep them.
- [ ] `comment-reply.js` loads only where 07's rules allow.
- [ ] Federated comment fixture renders correctly.

## Tests required
- e2e: submit comment flow; validation messages announced; reply flow by keyboard.
- e2e: no requests to `gravatar.com` (if avatars off).
- axe on a post with threaded comments and the form, both schemes.

## Quality notes
- Security: core handles nonces/escaping; theme must not output comment fields unescaped in custom markup.
- Privacy: no third-party requests; cookie checkbox kept.

## Team lead
Get Kyle's decision on avatars and the website field before briefing.

## Review focus
- Any custom comment markup escaping.
- Behaviour with the cache: a logged-out visitor without cookies never sees someone else's pending comment.

## Human-gated steps
None.

## Follow-ups
