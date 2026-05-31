.pragma library
// Pure launch-bar parser. .pragma library = stateless singleton, no QML
// scope — so QuickBar.qml never tokenizes inline and this stays unit-
// testable on its own. See docs/superpowers/specs/2026-06-01-launch-bar-
// completion-plan.md §2 for the grammar.

function isSpace(c) {
  return c === " " || c === "\t" || c === "\n" || c === "\r";
}

// parse(text, cursor) -> {
//   directives: { <key>: <value>, … },   // leading /key:value pairs, last wins
//   prompt: "…",                          // remainder after the directives
//   cursorToken: { kind, key, partial },  // what Tab acts on at `cursor`
// }   kind ∈ "slash" | "key" | "value" | "prompt"
//
// Directives are leading-only: the first token that isn't a leading `/…`
// ends directive parsing and everything from there is prompt verbatim.
// Within a `/…` token KEY is the text up to the FIRST `:`, and VALUE runs
// from that `:` to the next whitespace — so the value keeps its own colon
// (/model:gemma4:e4b → value "gemma4:e4b"). A `/…` with no colon is a bare
// command (e.g. /help), consumed but not a directive.
function parse(text, cursor) {
  text = text || "";
  if (typeof cursor !== "number") cursor = parseInt(cursor, 10);
  if (isNaN(cursor) || cursor < 0 || cursor > text.length) cursor = text.length;

  const len = text.length;
  const directives = {};
  const tokens = [];
  let i = 0;
  let promptStart = 0;

  while (true) {
    while (i < len && isSpace(text[i])) i++;
    const start = i;
    if (i >= len || text[i] !== "/") {
      promptStart = start;
      break;
    }

    let j = i + 1;
    while (j < len && text[j] !== ":" && !isSpace(text[j])) j++;
    const key = text.slice(i + 1, j);

    if (j < len && text[j] === ":") {
      let valueStart = j + 1;
      // Tolerate one optional space after `:` ("/model: gemma4:e4b").
      if (valueStart < len && text[valueStart] === " ") valueStart++;
      let k = valueStart;
      while (k < len && !isSpace(text[k])) k++;
      directives[key] = text.slice(valueStart, k);
      tokens.push({ start, end: k, key, colonPos: j, valueStart });
      i = k;
    } else {
      // Bare command (/verb): consumed, but not a /key:value directive.
      tokens.push({ start, end: j, key, colonPos: -1, valueStart: -1 });
      i = j;
    }
  }

  const prompt = text.slice(promptStart).replace(/^\s+/, "");
  return { directives, prompt, cursorToken: classify(text, cursor, tokens) };
}

function classify(text, cursor, tokens) {
  for (let t = 0; t < tokens.length; t++) {
    const tok = tokens[t];
    // `end` is exclusive of the trailing whitespace separator, so
    // cursor == end is the caret at the value's end (still this token),
    // while a cursor past it falls through to the prompt.
    if (cursor < tok.start || cursor > tok.end) continue;

    if (tok.colonPos === -1) {
      // A lone "/" opens the directive-key menu; anything after it is a
      // key (or command verb) being typed.
      if (tok.key === "") return { kind: "slash", key: "", partial: "" };
      return { kind: "key", key: "", partial: text.slice(tok.start + 1, cursor) };
    }
    // The colon commits the key, so a caret resting on it (cursor ==
    // colonPos) already reads as value-mode with an empty partial.
    if (cursor < tok.colonPos) {
      return { kind: "key", key: "", partial: text.slice(tok.start + 1, cursor) };
    }
    return {
      kind: "value",
      key: tok.key,
      partial: cursor > tok.valueStart ? text.slice(tok.valueStart, cursor) : "",
    };
  }
  return { kind: "prompt", key: "", partial: "" };
}
