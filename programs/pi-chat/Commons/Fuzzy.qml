// Fuzzy subsequence matching for filtering short label lists (the
// model selector dropdown).
//
// `score(query, text)` returns a rank >= 0 when `query` matches `text`
// — case-insensitively, as an order-preserving subsequence — or -1 when
// it does not. Higher ranks are better. A contiguous substring hit
// outranks every scattered-subsequence hit, an earlier hit outranks a
// later one, and a hit aligned to a word boundary (start of string or
// just after a separator) earns a bonus. `filter()` applies the score
// across a list and returns the matches best-first, with equal-score
// ties broken by the item's original index so an already-ordered input
// (e.g. frecency-sorted models) is preserved among equally-good matches.
pragma Singleton

import QtQuick

QtObject {
  id: root

  // Characters that begin a "word": a query char landing right after one
  // (or at position 0) is treated as boundary-aligned and scores higher,
  // so typing "gpt" favours "[openrouter] gpt-4o" over a model that only
  // contains those letters mid-token.
  function _isBoundary(ch) {
    return ch === " " || ch === "/" || ch === "_" || ch === "-"
      || ch === "." || ch === "[" || ch === "]" || ch === ":";
  }

  // Match `query` against `text`, compared case-insensitively. Returns
  // -1 for no match, else a score (see file header for the ranking).
  function score(query, text) {
    const t = String(text === undefined || text === null ? "" : text);
    const q = String(query === undefined || query === null ? "" : query);
    if (q.length === 0) return 0;
    if (q.length > t.length) return -1;
    const tl = t.toLowerCase();
    const ql = q.toLowerCase();

    // Fast path: contiguous substring. The 1000 base guarantees any
    // substring hit outranks every scattered subsequence below.
    const idx = tl.indexOf(ql);
    if (idx >= 0) {
      let s = 1000 - idx;
      if (idx === 0 || root._isBoundary(t[idx - 1])) s += 100;
      return s;
    }

    // Subsequence: every query char must appear in order. Reward
    // adjacency (streaks) and boundary-aligned characters.
    let ti = 0;
    let s = 0;
    let streak = 0;
    let prev = -2;
    for (let qi = 0; qi < ql.length; qi++) {
      const c = ql[qi];
      let found = -1;
      for (; ti < tl.length; ti++) {
        if (tl[ti] === c) { found = ti; break; }
      }
      if (found < 0) return -1;
      if (found === prev + 1) { streak += 1; s += 4 + streak; }
      else { streak = 0; }
      if (found === 0 || root._isBoundary(t[found - 1])) s += 8;
      prev = found;
      ti = found + 1;
    }
    return s;
  }

  // Return a NEW array of the entries of `items` that match `query`,
  // ranked best-first. `textOf(item)` yields the string to match. An
  // empty query returns a shallow copy of `items` unchanged, so callers
  // can use this as the single source of a filtered list.
  function filter(items, query, textOf) {
    const arr = Array.isArray(items) ? items : [];
    const q = String(query === undefined || query === null ? "" : query);
    if (q.length === 0) return arr.slice();
    const scored = [];
    for (let i = 0; i < arr.length; i++) {
      const s = root.score(q, textOf(arr[i]));
      if (s >= 0) scored.push({ item: arr[i], s: s, i: i });
    }
    scored.sort((a, b) => (b.s !== a.s) ? (b.s - a.s) : (a.i - b.i));
    return scored.map(d => d.item);
  }
}
