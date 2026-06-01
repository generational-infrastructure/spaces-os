---
name: Wikipedia
description: Look up encyclopedic facts and article text from Wikipedia via the public MediaWiki API
---

Use `wikipedia-cli` to search Wikipedia, read a short factual summary, or
pull the full plaintext of an article. No account or API key is needed.

### Search for an article

```bash
wikipedia-cli search "theory of relativity"
wikipedia-cli search "Einstein" --limit 3
```

Returns each hit's title, page ID, and a plain-text snippet. Use this first
to resolve a vague query to an *exact* article title before calling
`summary` or `content`.

### Get a quick summary

```bash
wikipedia-cli summary "Albert Einstein"
```

Returns the title, a one-line description, the lead-paragraph extract, and
the canonical page URL. This is the fastest path to a single factual answer.

### Read the full article

```bash
wikipedia-cli content "Albert Einstein"
wikipedia-cli content "Albert Einstein" --intro
```

Prints the plain-text article body. Pass `--intro` to get only the lead
section instead of the whole page — cheaper when you just need the opening.

### Tips

- Workflow: `wikipedia-cli search "<query>"` to find the exact title, then
  `wikipedia-cli summary "<title>"` for a fast answer or
  `wikipedia-cli content "<title>"` for the full text.
- Every verb takes `--lang <code>` (default `en`) to query a non-English
  edition, e.g. `wikipedia-cli summary "Berlin" --lang de`.
- Titles are case- and spelling-sensitive; prefer the exact title that
  `search` returns over guessing.
