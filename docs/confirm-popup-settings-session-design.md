# Design: confirm popup UX, settings menu restyle, per-process session grants

Goals from `.direnv/goals.md` (2026-07-15). Three deliverables.

## 1. Tool-call confirmation popup

Current state (`programs/spaces-integration-confirm/shell.qml`):
- args rendered as one `JSON.stringify(args, null, 2)` monospace blob;
- root is Quickshell `FloatingWindow` — an ordinary xdg toplevel that niri
  tiles into a full workspace column ("fullscreens");
- ad-hoc Catppuccin-ish palette, hand-rolled buttons.

### 1.1 Per-field rendering

Replace the JSON blob with a field list derived from `request.args`:

- one row per top-level key: MONO UPPERCASE caption label (the key) over a
  value well;
- scalar values (string/number/bool/null) render as plain mono text, wrapped;
- nested objects/arrays render as pretty-printed JSON inside the same well
  (still per-field, so a `recipient` scalar never drowns in punctuation);
- everything stays `Text.PlainText` — args and context are untrusted.

The IPC seam (`IpcHandler target:"confirm"`: `decide`, `toolName`,
`argsText`, `context`) is kept verbatim; `argsText` remains the JSON
serialization so the contract check and the gateway-side semantics
("the human sees exactly what runs") are unchanged. The contract check
gains assertions for the per-field surface (field count + labels).

### 1.2 Real popup, not a tiled window

Root becomes a Quickshell `PanelWindow` with
`WlrLayershell.layer: WlrLayer.Overlay`, no anchors (a layer surface with no
anchors is centered by the compositor), `keyboardFocus: OnDemand`, sized to
content with a max height. Under niri this renders as a floating overlay
above everything and is never tiled. `QT_QPA_PLATFORM=offscreen` checks keep
working (pi-chat's QuickBar is already a PanelWindow booted offscreen by the
pi-session checks).

Fallback risk: a non-layershell compositor. Quickshell degrades PanelWindow
without layer-shell support; the popup remains a standalone window there.
Acceptable — target compositor is niri.

### 1.3 Voxtype styling

Port the voxtype-tuner design tokens (packages/voxtype-tuner/ui/theme.slint,
dark scheme) into the popup's self-contained palette (the popup deliberately
imports no harness QML, so tokens are copied, not shared):

- window #151b1e, card #222c30, control #2f3c42, text #ffffff/#afc6ca,
  accent = white ink w/ #151b1e on-accent, danger #c43e81 (+white),
  border-soft #465a62, border-strong #617e89;
- card radius 16 + 1px border-soft; buttons are full pills (radius = h/2,
  h 40): Deny = danger pill, Allow once = secondary (control fill +
  border-strong hairline), Allow for session = primary (accent fill);
- MONO UPPERCASE 12px secondary captions for section/field labels; mono
  values; 180ms hover transitions; title 18 SemiBold.

## 2. Settings window restyle

`programs/pi-chat/SettingsWindow.qml` stays a `FloatingWindow` (a settings
dialog is a normal window by design) and keeps:

- every `objectName` consumed by checks/pi-session-integrations-{bridge,
  managed,setup} (setupBtn-, enableToggle-, enableManagedLabel-, cfgInput-,
  cfgRow-, secInput-, secretBadge-, lockBadge-, shadowBadge-, profileRemove-,
  addProfileInput-, draftError-, setupQr, setupPrompt, setupPromptInput,
  setupSubmit, setupStatus, profileEditor-);
- the `integrationsSockPath` override, the managed read-only invariant
  (affordances absent, not disabled), the setup-pane exclusivity rule;
- the `Color.m…` palette (the panel mirrors noctalia's scheme; foregrounds
  keep their matching `mOn…` entries per AGENTS.md).

Adopted from voxtype: the layout language, not the palette —

- each integration becomes a **card** (mSurfaceVariant well, radius 16,
  1px mOutline hairline, 16px padding) instead of a flat run of rows;
- section headers become MONO UPPERCASE captions (mOnSurfaceVariant);
- config/secret field rows get the caption-over-input arrangement with the
  label in mono uppercase and status badges as small pills;
- the enabled badge becomes a dot + mono caption status chip;
- window grows to 560×640 default so cards breathe.

New local components (private to SettingsWindow): `SCard`, `SSectionLabel`,
`SStatusChip`. Widgets/N* stay untouched (used elsewhere).

Strings: no new user-visible strings expected; any change updates all 11
locales in `programs/pi-chat/i18n/`.

## 3. Per-process "allow for session" grants

### Problem

A session grant today lives in a per-connection `Set` (`mcp-server.ts`,
`GatewaySession.grants`). That is *incidentally* per-process for the two
existing clients (pi holds one persistent connection per pi process; each
MCP-native harness spawns one `spaces-mcp-connect` bridge = one connection),
but:

- a reconnect (gateway restart aside) silently drops grants (backlog #4);
- a harness that opens multiple connections per process re-prompts each time;
- the semantics are nowhere explicit.

### Options considered

1. **SO_PEERCRED** on the gateway's unix socket: gives (pid, uid, gid) of the
   direct peer. Rejected: Bun's `node:net` exposes no `getsockopt`
   (FFI hack required); the pid seen for MCP-native harnesses is the *bridge*
   pid, not the agent (walking `/proc/<pid>/status` PPid chains is racy and
   guessy); pids recycle. Multi-user is already solved structurally — the
   gateway is a systemd **--user** service with its socket in `%t` (0700),
   one instance per user, so a grant can never leak across users.
2. **Per-call `session` field** on every tool schema (goals.md fallback):
   works but pollutes every tool's input schema and burns model tokens.
3. **Connection-scoped session key, declared once** — chosen.

### Chosen design: client-declared session key

- New notification `spaces/session` with params `{ key: string }`. A client
  sends it once right after connecting (before any `tools/call`). The
  gateway binds that connection's grant set to a shared per-key entry.
- Key = cryptographically random value **generated in the agent process's
  memory**, so its lifetime is exactly the process lifetime: a new process
  can never present an old key, and grants keyed to it die with the process.
- `pi-chat-extensions/spaces-integrations.ts`: generate one key per pi
  process (module scope), send the notification after connect.
- `connect.ts` (spaces-mcp-connect): generate one key per bridge process and
  write the notification as the first socket line before piping stdin —
  explicit per-process semantics for MCP-native harnesses too.
- Gateway (`mcp-server.ts` + `main.ts`): grant store
  `Map<key, { grants: Set<string>, refs: number, idleSince: number }>`;
  a connection without the notification keeps today's private per-connection
  set. Entries are dropped when unreferenced for 30 min (swept lazily on new
  connections) — a dead process's key never returns, so retention is only a
  memory-hygiene concern.
- Confirm popup semantics unchanged: verdict `session` adds the tool to the
  connection's (now possibly shared) grant set.

Untrusted-key concern: any same-user process could send any key. That is the
existing trust model — the socket is same-user only; a same-user process can
already answer its own confirm prompts. No privilege boundary crossed.

### Tests

- `mcp-server.test.ts`: two sessions sharing one key — grant made through
  connection A applies on connection B; different keys stay isolated;
  key-less connections keep per-connection behavior.
- `connect.test.ts`: bridge writes the `spaces/session` notification as its
  first line, before client bytes; distinct bridge invocations use distinct
  keys.
- `spaces-integrations` extension: key notification sent on connect
  (covered by the gateway-side tests + e2e).

## Verification

- checks: spaces-integration-confirm, spaces-integration-gateway-unit,
  pi-session-integrations-{bridge,managed,setup}.
- agent-vm: boot, open the settings window (`quickshell ipc … settings`),
  screenshot, inspect with vision; spawn `spaces-integration-confirm` with a
  fixture request in the VM session, screenshot, verify it renders as a
  centered overlay (not a tiled column) with per-field args.
