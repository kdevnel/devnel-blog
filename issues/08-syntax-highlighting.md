# 08. Server-side syntax highlighting

**Wave:** 1 · **Depends on:** 04 · **Implementer:** Sonnet · **Reviewer:** Opus

## Goal
`core/code` blocks come out highlighted as static HTML, coloured by theme tokens in both schemes, with no JS for readers, replacing SyntaxHighlighter Evolved.

## Context
- DECISIONS D6. 15 `syntaxhighlighter/code` blocks get converted to `core/code` by issue 13; this issue makes `core/code` render well.
- Language source: a `language-xxx` class on `<code>` (what 13 writes and what authors can add through "Additional CSS class"), or a block attribute if a small editor control is added (optional, see Scope).

## Scope
In: `inc/highlighting.php`, a Composer library, token CSS, caching, tests.
Out: content conversion (13); a custom language picker in the editor (Follow-up unless trivial).

## Deliverables
- Library choice: **highlight.php** (`scrivo/highlight.php`, pure PHP, highlight.js grammars) or **Phiki** (TextMate grammars, PHP 8.2+). Pick one, justify it in a DECISIONS entry (size, maintenance, language coverage: php, js, ts, bash, css, html, json, sql, yaml, diff at minimum). Install into `theme/devnel/vendor` with a scoped/prefixed autoloader (e.g. via `humbug/php-scoper` or Strauss) so it can't clash with plugins.
- `render_block_core/code` filter: reads the language, highlights the decoded text, re-escapes safely, wraps in `<pre class="wp-block-code" tabindex="0" aria-label="Code: <language>"><code class="language-x hljs">…`. Unknown or missing language → plain escaped text (no auto-detect, since it's slow and unreliable).
- Cache: `wp_cache_get/set` (Redis on prod) keyed by `md5(language . content . library version)`, falling back to no cache; no transients in the options table.
- `styles/blocks/code.css`: token colours as `--devnel-code-*` variables with light and dark values meeting AA against the code background; long lines scroll, never wrap mid-token; mono font from 04.
- Copy-to-clipboard: **no** (JS). Record as a possible follow-up.

## Acceptance criteria
- [ ] Fixture code blocks in each listed language render highlighted with zero front-end JS.
- [ ] Output is safe: highlighting `<script>alert(1)</script>` or `"><img onerror>` content produces escaped text only.
- [ ] Token colours pass AA in both schemes (`npm run contrast` extended with code tokens).
- [ ] Rendering a cached block avoids calling the highlighter (PHPUnit with a spy).
- [ ] phpcs/phpstan pass; vendored library excluded from phpcs but included in `composer audit`.
- [ ] SyntaxHighlighter plugin can be deactivated in wp-env without visible change on converted content (verify with 13's conversion on a copy).

## Tests required
- PHPUnit: language detection from class; unknown language fallback; XSS payloads; cache hit/miss; markup shape (`tabindex`, `aria-label`).
- e2e: code fixture post has `.hljs` spans and no `<script>` from the theme; axe passes (scrollable region focusable).
- Visual snapshot for the code fixture in both schemes.

## Quality notes
- Performance: highlighting cost hits only uncached requests; record time for the biggest fixture block.
- Security: never output the library's HTML without checking it's the escaped form; reviewer checks this.
- Maintenance: library pinned; Dependabot covers composer.

## Team lead
Ask the implementer for a one-paragraph library comparison before building; approve the choice.

## Review focus
- Escaping order (decode → highlight → library escapes → no double-escape and no raw passthrough).
- Prefixing actually prevents class collisions.
- Cache key includes library version so upgrades refresh output.

## Human-gated steps
None.

## Follow-ups
