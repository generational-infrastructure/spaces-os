# Launch-bar completion — implementation plan

**Date:** 2026-06-01
**Status:** Reviewed (2× feasibility/convention claude + 1× design codex);
blocker fixed; grammar chosen (`/model:` slash-directive, 2026-06-01);
pending approval
**Base branch:** `ke-launch-bar-commands`
**Builds on:** `docs/superpowers/specs/2026-05-31-quick-launch-agent-bar-design.md`

## 0. Naming — what this thing is called

The surface (`programs/pi-chat/QuickBar.qml`) is the **quick-launch bar**.
The feature added here is **launch directives with Tab completion** — a
compact, shell-style completion surface, not a desktop app launcher and not
(yet) a VS Code-style command palette.

Vocabulary used throughout this plan, and what to call things in code/UI:

- **Directive** — a leading **slash** token `​/key:value` that configures the
  launch, e.g. `/model:gemma4:e4b`. The `/` is the trigger (discoverable: typing
  `/` opens the directive menu); `:` separates key from value. *(Decision:
  2026-06-01, user chose `/model: <name>` over a bare `model:`.)*
- **Command** — a bare `/verb` with no `:` that *does* something other than
  launch (e.g. `/help`). Same `/` namespace as directives, distinguished by the
  absence of `:`. Reserved for later; not in the MVP.
- **Completion** — the Tab-driven candidate list + accept behavior.

**File/identifier naming decision:** keep `QuickBar.qml`, the `quickLaunch`
IPC verb, the `Mod+/` bind, and the `quickbar.*` i18n namespace **as-is** for
this iteration. Renaming to `AgentCommandBar` cascades through `shell.qml`,
the niri bind, every locale file, and `checks/pi-session-quick-launch`, and
that churn is only justified once the grammar grows a second directive or a
real `/command`. **Defer the rename** to a dedicated cleanup change; this plan
notes the trigger (second directive lands) so it isn't forgotten.

> If the user wants the user-facing concept named now, the recommendation is
> **"command bar"** (interaction) with **"launch directives"** (the tokens).
> "Spotlight"/"quick-launch" stays as the internal nickname.

**Supersedes a base-spec non-goal.** The 2026-05-31 design spec lists "A model
picker / options in the bar" as an explicit **Non-goal** (and confirmed-default
#1: "same default model a new chat would"). This plan deliberately reverses that
one non-goal while preserving the others (background launch, notification
suppression, session-in-index). When this lands, flip that spec's Non-goal to a
"superseded by 2026-06-01-launch-bar-completion" note so the two docs stay
coherent. All other base-spec behavior is unchanged.

## 1. Scope

**MVP (this plan):** one directive — `/model:` — with three-state Tab
completion, plus the parser/grammar boundary and the backend launch-options
path that future directives reuse.

Interaction (the canonical flow from the request):

```
/             → Tab → directive menu ([/model:])   (slash triggers; menu is discoverable)
/m            → Tab → /model:                      (complete directive key)
/model:       → Tab → [list of model ids]          (open value candidates)
/model:g      → Tab → /model:gemma4:e4b            (complete the value)
<space> summarize the repo  → Enter                (launch: model gemma, prompt "summarize the repo")
```

Note the value `gemma4:e4b` itself contains a `:` — see §2 for the split rule.

**Deferred (explicitly out):** `/` commands (`/help`, `/new`), `skill:`,
`cwd:`/`dir:`, `session:` resume, fuzzy matching, history, token "chips",
inline (non-leading) directives, the `QuickBar`→`AgentCommandBar` rename.
The architecture below leaves room for each without rework.

## 2. Grammar

One mechanism: **leading slash-directives, then free-form prompt.** Parsing
stops at the first token that doesn't start with `/`; everything after is the
prompt verbatim.

```
input     := directive* prompt
directive := '/' KEY ':' VALUE WS    # /model:gemma4:e4b
command   := '/' VERB WS             # /help   (no ':'; reserved, post-MVP)
prompt    := free text (the remainder, sent to the agent unmodified)
```

**Tokenizing rule (load-bearing — the value can contain `:`):** within a `/…`
token, `KEY` is the text between `/` and the **first** `:`; `VALUE` is
everything from that first `:` to the next **whitespace**. So `/model:gemma4:e4b`
→ key `model`, value `gemma4:e4b` (the second colon stays in the value). A
trailing-space form `/model: gemma4:e4b` is tolerated by skipping one optional
space after the `:` and then taking the next whitespace-delimited token as the
value. Model ids never contain spaces, so "value ends at whitespace" is
unambiguous against the following prompt.

- Directives are **leading-only** for the MVP. Inline directives collide with
  natural prose ("write about /model: syntax") and force escaping rules —
  not worth it now. A `/` that is *not* in leading position is plain prose.
- `model` is the only registered key. An unknown `/key:` (e.g. typo `/modle:`)
  is surfaced as an **unknown-directive** state (it's a leading `/`, so the user
  clearly meant a directive), not silently sent as prose.
- A leading bare `/verb` (no `:`) is a **command** — reserved namespace,
  post-MVP; for now it is a no-op that is never sent to the agent.

### Parser lives in a pure JS helper

Add `programs/pi-chat/BarParse.js` (QML's JS dialect). **`treefmt.nix` must
exclude it from prettier** (mirror the `MsgText.js`/`MsgFilter.js` entries,
`treefmt.nix:31`) — this is required, not optional: `prettier.includes` matches
`*.js`. It is pure (no QML
imports) so it is unit-testable on its own. It exports:

```js
// parse(text, cursor) -> {
//   directives: { model? },                      // resolved /key:value pairs
//   prompt: "…",                                 // remainder after directives
//   cursorToken: {                               // what Tab acts on, at `cursor`
//     kind: "slash"|"key"|"value"|"prompt",      // "slash" = just "/" typed → key menu
//     key:  "model" | "",                        // for kind:"value"
//     partial: "g"                               // text typed so far in this token
//   }
// }
```

`QuickBar.qml` only renders candidates and re-injects accepted text; it never
parses inline. `launchBackground` receives `parse(...).directives` +
`parse(...).prompt`.

## 3. Backend / data layer

### 3.1 The core problem: models before a session exists

The bar fires *before* any `PiSession` exists, but the model list today is a
per-session RPC (`PiSession.listModels()` → `get_available_models`). Solve it
with a **backend-owned model cache**, filled cheaply:

- Add to `PiChatBackend.qml`:
  - `property var modelsList: []`  — `[{ provider, id }]`
  - `property bool modelsLoaded: false`
  - `function refreshModels()` — one-shot GET of `llmUrl + "/v1/models"`
    (`llmUrl` already exists, `PiChatBackend.qml:80`). ⚠️ *Corrected after
    review:* there is **no `XMLHttpRequest` precedent** anywhere in the `.qml`
    tree, but `curl --fail http://127.0.0.1:8012/v1/models` is already exercised
    (`checks/test-pi-chat.py:141`) and the proven stdout-capture idiom is
    `Process` + `StdioCollector` (the image reader, `PiSession.qml:913-935`).
    **Use Process + StdioCollector**, not XHR. `/v1/models` returns bare `id`s →
    prefix each with the configured default provider, read as
    `root._cfg.defaultProvider` (it lives inside `configAdapter`, **not**
    re-aliased on the backend like `llmUrl` — a bare `defaultProvider` won't
    resolve), to form `{provider, id}`.
- **Warm it** on first bar open: add `backend.refreshModels()` (null-guarded) to
  `QuickBar.onVisibleChanged` (`QuickBar.qml:59-66`, where `bar.backend` is
  already used). Cheap; covers the default local-only llama-swap deployment with
  zero spawned process. `Component.onCompleted` is an acceptable alternative.
  Because `refreshModels()` is async, the first Tab on `/model:` may hit an
  empty/loading list — the completer must handle "candidates not ready yet"
  (show a loading/empty state, re-query on arrival), and §6 must test it.
- **Authoritative fallback:** when a live `PiSession` already has a richer
  list (e.g. OpenRouter models that `/v1/models` won't enumerate),
  `_maybeSpawn` already calls `s.listModels()` on panel open
  (`PiChatBackend.qml:385`). Forward `PiSession.models` →
  `backend.modelsList` by adding `onModelsChanged` to the `_piSessionComponent`
  (`PiChatBackend.qml:595-599`; no such signal handler exists today). **Dedup
  on the `provider+"/"+id` key** — the `/v1/models` cache and a live session's
  `local/*` entries collide on the same id and would otherwise double-list.
  Only spawn a dedicated hidden probe session if the cache is empty *and* a
  non-local provider is configured (rare; can be a follow-up).

Do **not** read `services.llama-swap.settings.models` from Nix — that data
isn't exposed to QML at runtime.

### 3.2 `launchBackground` grows options

Today: `launchBackground(prompt)` (`PiChatBackend.qml:264`) does
`newSession(summary)` → `obj.spawn()` → `obj.send(prompt)`.

Change to `launchBackground(prompt, opts)` where
`opts = { model?: "provider/id" }` (shape extensible for `cwd`, `skill`):

1. `newSession(name, opts)` (`:227`, calling `_freshSessionEntry` `:179`):
   set `entry.model = opts.model || ""` (the entry already carries a `model`
   string field, `:185`). `workspacePath` stays default for the MVP (`cwd:`
   deferred).
2. In `launchBackground`, after `obj.spawn()` and **before** `obj.send(prompt)`:
   if `opts.model`, split on the first `/` and apply the model — **awaiting the
   `set_model` response before sending the prompt.** ⚠️ *Corrected after
   review:* the naive `setModel(); send()` pair **races**. The in-tree comment
   at `PiSession.qml:216-220` is explicit: "pi's RPC pump dispatches stdin lines
   as fire-and-forget async tasks, so we cannot fire set_model immediately …
   they'd race." `setModel()` is fire-and-forget `_send` (`:253-259`); the turn
   could start on the default model. **Fix:** mirror `restart()`'s pattern —
   `obj._request({type:"set_model", …}).then(() => obj.send(prompt))` (the
   `set_model` response branch already exists, `:789`). For a cold `spawn()` the
   model is never auto-applied (only `restart()`/`setModel()` emit `set_model`),
   so the directive *must* go over RPC and *must* be awaited. The e2e check
   (§6.2) only becomes deterministic once this is fixed.
3. `promptSummary`/title and the completion notification use the **prompt**
   (directives stripped), not the raw input. Since the bar now passes the
   already-stripped `prompt`, this is automatic.

### 3.3 Model identity (display ↔ id)

pi uses `provider/id` everywhere (`setModel` joins them, `PiSession.qml:254`;
matching is `provider+"/"+id === modelPref`, `:785`). The cache stores
`{provider, id}`. Completion **shows the friendly `id`** (e.g. `gemma4:e4b`)
and resolves to `provider/id` before launch. Prefer a cached session's
explicit `provider`; otherwise default-prefix with `defaultProvider`.

## 4. UI layer (QML)

### 4.1 Completion surface — in-window overlay, no second layer-shell

The bar already holds `WlrKeyboardFocus.Exclusive` (`QuickBar.qml:43`). A
second layer-shell surface would fight the single keyboard grab; a QtQuick
`Popup` clips to the (short) window content and would be cut off above the
input. **Instead:** render the candidate list as a sibling `Rectangle` *inside
the existing `PanelWindow`*, and make `implicitHeight` conditional so the
bottom-anchored surface **grows upward** when completion is active —
suggestions appear exactly above the input, inside the one focused surface.

New file `programs/pi-chat/QuickBarCompletion.qml`: the overlay list + a small
controller. Reuse `Widgets/NListView.qml` for the list and copy
`NComboBox.qml:72-89`'s delegate idiom (`NText` + highlight `Rectangle` keyed
on selected index, `mPrimary`/`mOnPrimary` selected, `mOnSurface` otherwise).
Surface styling mirrors the bar (`Color.mSurface`/`mOutline`/`radiusS`,
`QuickBar.qml:71-74`).

### 4.2 Keyboard contract (the exact semantics — pin this before coding)

Review flagged the original draft left "does Tab insert the first match or just
reveal the list?" undefined. Locked decision — **Tab never silently picks among
ambiguous candidates** (that would be destructive):

| State | Tab | Up/Down | Enter | Esc |
|---|---|---|---|---|
| Bare `/` typed | open directive-key menu (`/model:`), select first, **no mutation** | open+move | launch (if prompt non-empty) | hide bar |
| `/m` → unique key prefix | complete to `/model:`, open value list | — | (list closed) launch | hide bar |
| `/mo…` ambiguous key | insert longest common prefix, keep key menu open | move selection | launch | hide bar |
| `/model:` empty value | open value list, select first, no mutation | move selection | accept selected | close list |
| `/model:g`, one match | complete to `/model:gemma4:e4b` | — | accept | close list |
| `/model:g`, many matches | insert **longest common prefix only**, keep list open | move selection | accept selected | close list |
| List open | accept highlighted candidate | move selection | accept highlighted | close list (bar stays) |
| No `/` (plain prose) | default focus-nav suppressed; no-op | — | launch | hide bar |

`Shift+Tab` moves selection backward when the list is open; otherwise ignored.
Every row of this table is a test case in §6.

### 4.3 Key handling / Tab semantics

`NTextInput` is a bare `TextField` (`NTextInput.qml:12`) which lets Tab move
focus by default. Attach a `Keys.onPressed` **at the call site in
`QuickBar.qml`** (where `Keys.onEscapePressed` already lives, `:93`) — leaving
the generic `NTextInput` untouched:

```qml
Keys.onPressed: (event) => {
  if (event.key === Qt.Key_Tab)       { completer.advance();  event.accepted = true; }
  else if (event.key === Qt.Key_Down) { completer.move(1);    event.accepted = true; }
  else if (event.key === Qt.Key_Up)   { completer.move(-1);   event.accepted = true; }
  else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && completer.active) {
    completer.accept(); event.accepted = true;   // accept candidate, do NOT launch
  }
  // Return/Enter with completer closed: fall through → onAccepted → bar.launch()
}
```

`Keys.onEscapePressed`: if `completer.active`, close the list
(`event.accepted = true`); else keep the current "hide the bar" behavior. The
existing launch flow (`onAccepted: bar.launch()`, `:92`) is preserved verbatim
whenever completion is not active — guaranteed by the `completer.active` guard
ordering.

### 4.4 Controller state (`completer`)

A `QtObject`/component root holding: `active: bool`, `mode: int`
(Key / Value — named JS consts, **not** a QML `enum`, to stay qmllint-clean),
`candidates: var` (`[{id, label}]` from `backend.modelsList`),
`selectedIndex: int`, and `partial/prefix/suffix` strings so `accept()` is
`text = prefix + chosen + suffix` with the caret re-placed. Methods
`advance()`, `move(d)`, `accept()` mirror `NComboBox`'s key↔index
encapsulation (`NComboBox.qml:47-70`).

### 4.5 Token rendering — plain text

Keep the input plain (no per-token "chips" — `TextField` is single-color and
chips need rich-text/overlay machinery that costs qmllint debt). The candidate
list conveys state. **Optional, deferrable:** ghost-text remainder at the
caret in `mOnSurfaceVariant` for an inline-completion feel — cut it from the
first slice if it complicates anything.

### 4.6 qmllint (`--max-warnings 0`, no suppressions)

- Candidate `var` model: use `required property var modelData` + null-guards in
  the delegate, exactly as `NComboBox.qml:52-68,78-82` does.
- Conditional `implicitHeight` stays a pure ternary on `completer.active`
  (matches the computed-height idiom at `QuickBar.qml:39`) — no binding loop.
- `Qt.Key_*` enums need no extra import; `mode` is `int` + consts, not a QML
  `enum` block in a non-singleton.

### 4.7 Discoverability (added after review)

Nothing currently tells a user directives exist (the bar reads only "Launch an
agent…" / "↵ launch"). Cheapest self-revealing fixes, all in `QuickBar.qml`:

- Placeholder hints the mode: e.g. `"Launch an agent…  ( / for options )"`.
- Trailing hint gains `"/ options"` beside `"↵ launch"`.
- **Typing `/` opens the directive-key menu** (`/model:` is the only entry
  today) — the slash is the self-revealing trigger, exactly the VS Code /
  Slack-style affordance the `/` syntax buys us. (Tab on an empty bar can also
  open it.)

## 4a. Behavioral edges & failure modes (added after review)

The original draft under-specified these; each is a locked decision + a §6 test:

- **Directive-only input is a no-op.** `QuickBar.launch()` guards
  `input.text.trim() === ""` on the **raw** text (`QuickBar.qml:50`). With
  directives, `/model:gemma4:e4b` (no prompt) is non-empty raw but empty after
  stripping — it must **not** `launchBackground("")` (spec default #3: empty
  Enter = no-op). Move the empty-check onto the **stripped prompt**.
- **Invalid model value never silently launches on the default.**
  `/model:bogus summarize` must not look accepted while being ignored. On Enter
  with an unresolved `/model:` value: keep the bar open, show the candidate list
  (or an inline invalid state). Do not strip-and-launch.
- **Unknown leading directive key.** `/modle:gemma …` (typo) → surface an
  "unknown directive" state (the leading `/` shows clear intent), never sent as
  prose. A non-leading `/` mid-text stays prose.
- **Duplicate `/model:` tokens** → last wins, with the replacement visible.
- **Bare leading `/verb`** (no `:`, e.g. `/help`) → reserved command namespace,
  post-MVP no-op; never sent to the agent.

## 5. i18n

New user-visible strings (e.g. a "⇥ complete" hint beside the existing
"↵ launch", and any "no matches" text) added to **all 11** locale files under
`programs/pi-chat/i18n/*.json`, identical key sets, `en.json` as source of
truth. Namespace under `quickbar.*` (kept despite the deferred rename).

## 6. Testing (TDD — cheap headless tier, per AGENTS.md)

The existing `checks/pi-session-quick-launch` is the harness pattern: stage the
real `programs/pi-chat` tree, swap only `shell.qml`, run `quickshell`
offscreen, drive via `quickshell ipc … call test:quick-launch <verb>`. The
driver does **not** inject raw key events — it calls test-only IPC verbs that
invoke the same QML functions the key handlers use.

1. **`checks/pi-session-quick-launch-completion`** (parser + UI contract, no LLM
   needed for most of it): test-only IPC verbs `setInput(text,cursor)`,
   `pressTab()`, `pressUp()`, `pressDown()`, `pressEscape()`, `pressEnter()`,
   `candidateTexts()`, `selectedCandidate()`, `inputText()`. Assert: `/`+Tab →
   directive menu lists `/model:`; `/m`+Tab → `/model:`; `/model:`+Tab → value
   list shown; `/model:g`+Tab → `inputText()` becomes `/model:gemma4:e4b`
   (the value's own `:` preserved — the split-rule test); selection move wraps
   deterministically; Esc closes list then (2nd Esc) hides bar.
2. **`checks/pi-session-quick-launch-model-directive`** (end-to-end, cheap): real
   `PiChatBackend` + `fake-systemd-run` + stub `notify-send` + `mock-llm.py`.
   Launch `/model:gemma4:e4b summarize logs`; assert the mock LLM request used
   `gemma4:e4b` (via `set_model`), the session title/notification summarize
   **"summarize logs"** (directive stripped), and the session is selectable
   afterward.
3. **`checks/pi-chat-completion-grammar`** (optional, fastest): no pi, no LLM —
   import `BarParse.js` into a tiny shell and run the grammar matrix below.

**Mock model list:** extend `mock-llm.py` to serve `/v1/models` (and the RPC
model list) from `MOCK_MODELS_JSON` env, default `["mock-model"]`; completion
checks set `["gemma4:e4b","gpt-oss","gpt-oss-120b","llama-3.2","mistral"]`. No
hard-coded model names in production QML.

**Grammar / behavior matrix** (each is asserted; the §4.2 keyboard table and the
§4a edges are all here): empty prefix + Tab → directive names, no arbitrary
insert; no match → input/cursor unchanged, list empty; ambiguous prefix → longest
common prefix inserted, list stays open, deterministic selection; complete then
edit → candidates recomputed, cursor-relative replacement preserved; directive +
prompt → model applied, prompt stripped; **the `:`-in-value split**
(`/model:gemma4:e4b` → key `model`, value `gemma4:e4b`); **directive-only
(`/model:gemma4:e4b` no prompt) + Enter → no-op** (spec default #3); **invalid
`/model:bogus` + Enter → bar stays open, no launch on default**; **unknown
leading `/key:` → "unknown directive" state, not sent as prose** (assert on the
launch path, not just completion); **duplicate `/model:` → last wins**;
**`/model:` Tab before `refreshModels()` resolves → loading/empty state, then
populated**; **bare `/verb` → never sent to the agent**; Esc mid-completion →
closes list first (2nd Esc
hides bar); unicode prompt survives stripping; very long list →
capped/virtualized, selected item visible.

**Gates:** `checks/pi-chat-qmllint` (zero warnings, no new
`QMLLINT-DEBT.md` entries); i18n key-set parity across all 11 locales;
`agent-vm` manual visual pass (bar grows upward, list legible, `mOn*` contrast
in hover/selected states).

## 7. File-change summary

| File | Change |
|---|---|
| `programs/pi-chat/BarParse.js` | **New.** Pure parser: `parse(text,cursor)` → directives/prompt/cursorToken. |
| `programs/pi-chat/QuickBarCompletion.qml` | **New.** Overlay candidate list + `completer` controller. |
| `programs/pi-chat/QuickBar.qml` | Instantiate completion overlay; conditional `implicitHeight`; `Keys.onPressed` for Tab/arrows/Enter gated on `completer.active`; pass parsed `{prompt, directives}` to `launchBackground`. |
| `programs/pi-chat/PiChatBackend.qml` | `modelsList`/`modelsLoaded`/`refreshModels()` (GET `/v1/models`); forward `PiSession.models` → cache; `launchBackground(prompt, opts)`; `newSession(name, opts)` sets `entry.model`; apply `setModel` before `send`. |
| `programs/pi-chat/i18n/*.json` (×11) | Completion hint / "no matches" strings under `quickbar.*`. |
| `checks/pi-chat-completion-grammar/` | **New** pure-parser matrix check (`default.nix` required for blueprint to pick it up). |
| `checks/pi-session-quick-launch-completion/` | **New** cheap check (parser + UI via test IPC verbs). |
| `checks/pi-session-quick-launch-model-directive/` | **New** cheap e2e check (model applied, prompt stripped). |
| `checks/pi-session-quick-launch/mock-llm.py` | Serve models from `MOCK_MODELS_JSON`. |
| `treefmt.nix` | **Required:** exclude `BarParse.js` from prettier (mirror `MsgFilter.js`, `:31`). |

> Check dirs use the existing `pi-session-quick-launch` sibling spelling
> (not `quickbar-*`) to avoid introducing a third name beside `QuickBar.qml`
> and `pi-session-quick-launch`. Each new `checks/<name>/` needs its own
> `default.nix` to become a flake output (blueprint auto-discovery).

No change to `modules/nixos/niri.nix` (bind unchanged), `shell.qml` IPC verb
(`quickLaunch` unchanged), or the `QuickBar` name (rename deferred).

## 8. Build order (TDD)

1. ✅ `BarParse.js` + `checks/pi-chat-completion-grammar` (red → green): the pure
   grammar, no QML/LLM. Cheapest feedback loop.
2. Backend: `modelsList`/`refreshModels` + `launchBackground(prompt, opts)`;
   extend `mock-llm.py`; `checks/pi-session-quick-launch-model-directive` proves
   model-apply + prompt-strip end-to-end. **✓ done** (awaited `set_model`).
3. UI: `QuickBarCompletion.qml` + `QuickBar.qml` wiring;
   `checks/pi-session-quick-launch-completion` proves Tab/candidate/accept.
   **✓ done** (overlay grows upward, §4.2 table + §4a edges green; i18n
   parity + qmllint green; ghost-text §4.5 deferred; agent-vm visual pass
   pending).
4. i18n parity; qmllint; `agent-vm` visual pass.

## 9. Risks

- **Completion-engine sprawl** (the main risk per the architecture review):
  cursor-aware tokenization + ranking + async loading can balloon and couple to
  `QuickBar.qml`. Mitigation: the pure `BarParse.js` boundary + `/model:`-only
  MVP keep surface area small; the controller is the only QML-side state.
- **`/v1/models` ≠ full list** for non-local providers. Mitigation: live-session
  forwarding into the cache; hidden probe session only as a later fallback.
- **Exclusive-focus + growing surface** visual correctness — covered by the
  `agent-vm` manual pass and the contrast check.
- **Stdin ordering** of `set_model` vs `send` — relies on pi consuming lines in
  order (it does); the e2e check pins it.
