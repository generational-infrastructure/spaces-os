# Quick-launch agent bar — design

**Date:** 2026-05-31
**Status:** Approved (design); pending implementation plan
**Branch:** `feat/quick-launch-agent-bar`

## Summary

A second layer-shell surface for the `pi-chat` shell: a bottom-center
"Spotlight" input bar, summoned by `Mod+/`, where the user types a
prompt and presses Enter to **fire off an agent in the background**.
The bar hides immediately, the chat panel does **not** open, the agent
runs headless, and a desktop notification fires when it finishes.

The launched session is a **normal `pi-chat` session** — the same kind
the chat panel creates. It lands in the shared sessions index, so
opening the chat panel later (`Mod+A`) shows it already in the tab
strip, mid-conversation, ready to continue in the normal agent
interface. There is no separate process, session type, or bridging:
the quick bar and the chat panel are two surfaces of the one
`quickshell -c pi-chat` process sharing a single `PiChatBackend`.

## Goals

- Fire-and-forget agent launch from a global keybind without opening
  the chat panel.
- The result is a first-class session, continuable via `Mod+A`.
- Desktop notification on completion; otherwise silent.

## Non-goals

- Clickable / actionable notifications that jump to the session
  ("approach A"). Deferred — noctalia's `NotificationService` already
  supports actions (`ActionInvoked` over D-Bus), so this is a clean
  later add: fire the notification with an `open` action + a small
  listener calling `show` + `selectSession`. Not in this iteration.
- Any immediate launch confirmation. Launch is **silent** until the
  completion notification.
- A model picker / options in the bar. The bar is a single text input.

## Architecture

One process, two layer-shell surfaces:

- **Chat panel** — existing right-edge `PanelWindow` (`shell.qml`),
  toggled by `Mod+A`.
- **Quick bar** — new bottom-center `PanelWindow`, toggled by `Mod+/`.

Both share the single `PiChatBackend` instance and its sessions index.
A session is owned by the backend, not by either window, which is what
lets a launched session run with no visible UI.

### Components / files

| File | Change |
|---|---|
| `programs/pi-chat/QuickBar.qml` | **New.** The Spotlight bar surface. |
| `programs/pi-chat/shell.qml` | Instantiate `QuickBar`; add IPC verb `quickLaunch()`. |
| `programs/pi-chat/PiChatBackend.qml` | Add `launchBackground(prompt)`; adjust lazy-spawn/idle-reap loop; fire completion notification. |
| `modules/nixos/niri.nix` | New bind `Mod+Slash` → `spawn "pi-chat-toggle" "quickLaunch"`. |
| `modules/nixos/pi-chat/default.nix` | No change — `pi-chat` is already in the default `notificationForwarding.ignoredApps`; a new nix-eval check pins that invariant. |
| `docs/keybindings.md` | Document `Mod+/`. |
| `programs/pi-chat/i18n/*.json` | Bar strings (placeholder, hint) in all 11 locales; `en.json` is source of truth. |

### QuickBar.qml (visual: option B "Spotlight")

- Bottom-anchored layer-shell `PanelWindow`, horizontally centered,
  `exclusiveZone: 0`, `WlrLayer.Top`.
- A gap above the screen edge via `margins.bottom`.
- Width ~640 px, clamped for small/ultrawide screens (mirror the chat
  panel's clamp idiom).
- 14 px corner radius and `Color.mSurface`, matching the chat panel's
  surface + radius (radius derived from noctalia settings as the panel
  already does).
- Leading spark icon, an `NTextInput` (placeholder "Launch an
  agent…"), trailing "↵ launch" hint.
- **Grabs keyboard focus on show:** `WlrLayershell.keyboardFocus =
  visible ? Exclusive : None`. It is a modal input meant to capture
  typing; niri compositor binds still fire under Exclusive. (This is
  intentionally simpler than the chat panel's brief-Exclusive focus
  dance, which exists to *not* steal focus.)
- `Enter` with non-empty text → launch + hide. `Enter` with empty
  text → no-op. `Esc` → hide without launching.

### Backend changes (`PiChatBackend.qml`)

Current lazy-spawn/idle-reap loop (lines ~312–348) is panel-coupled in
two ways that fight a background launch. Both must change:

1. **Headless spawn.** `_maybeSpawn()` only spawns a session's `pi`
   process when `_panelOpen && active && !streaming` (the `_panelOpen`
   gate, line ~332). Add `launchBackground(prompt)` that:
   - `newSession(name = promptSummary(prompt))` — creates the session
     record (object, on-disk dir, tab entry).
   - calls `session.spawn()` **directly**, bypassing the `_panelOpen`
     gate, so the `pi --mode rpc` worker starts immediately with the
     panel closed.
   - `session.send(prompt)`.
   - marks the session as a pending background launch (a flag) so the
     reaper exempts it and the completion hook knows to notify.

   Rationale: `newSession()` alone only creates the *record* (enough to
   appear under `Mod+A`); it does **not** start the worker. Without an
   explicit spawn, `send()` has no running process to talk to and the
   agent never starts.

2. **Don't reap a streaming session.** The idle timer currently does
   `if (o.streaming) o.stop()` (line ~345), killing a long background
   task 10 min after the panel closes. Invert: the reaper must **skip
   streaming sessions** (and pending background launches), stopping
   only cold/idle ones. A fire-and-forget task that runs 30 min must
   survive.

### Completion notification

- On a background-launched session's `streaming` transition
  `true → false`, fire `notify-send` via a Quickshell `Process`.
- Title: **"Agent finished"**; body: the prompt summary.
- App name set so it is matched by
  `notificationForwarding.ignoredApps` — otherwise
  `distro-notify-forward` (which snoops every `Notify` and forwards it
  into chat as `[Notification] …`) re-injects our own notification into
  the active session. `pi-chat` is already in the default ignore list
  (the chat panel emits under that app name); a nix-eval check pins it.
- **Suppress** the notification if that session is the open + active
  session in the chat panel when it completes (the user is already
  watching it).
- Clear the pending-background flag once the notification fires (or is
  suppressed).

## Data flow

```
Mod+/  → pi-chat-toggle quickLaunch → IPC quickLaunch() → QuickBar shows, grabs keyboard
  type prompt, Enter (non-empty)
    → backend.launchBackground(prompt):
        newSession(name = promptSummary)        # normal session, in the index
        session.spawn()                          # headless — bypasses the panel-open gate
        session.send(prompt)
        mark session as pending background launch
    → QuickBar hides
  …session streams in the background, no window…
  streaming → false
    → unless that session is open+active: notify-send "Agent finished: <summary>"
    → clear pending-background flag
  later: Mod+A → chat panel opens → session already in tab strip → continue normally
```

## Behavioral defaults (confirmed)

1. Launched session uses the **same default model** a new chat would.
2. **Concurrent launches allowed** — each is its own session + process
   + completion notification.
3. `Esc` cancels (hide, no launch); **empty Enter is a no-op**.
4. Session **title derived from the prompt** (first line, ~40 chars).
5. **cwd = the same default workspace dir** a normal new chat uses.
6. **Suppress** the completion notification if the session is open and
   active at completion.
7. Notification text: title "Agent finished", body = prompt summary.

## Testing

Per `AGENTS.md`: per-feature behavior goes in cheap focused checks; the
VM is only for the visual/compositor bits.

- **`checks/pi-session-quick-launch`** (new, cheap): headless
  quickshell + mock LLM + a stub `notify-send` on `PATH`. Assert:
  1. the `quickLaunch`/`launchBackground` path creates a session and
     **spawns its `pi` process with the panel hidden**;
  2. the prompt streams a response;
  3. on completion the stub `notify-send` is invoked once with the
     expected text;
  4. the session is present and selectable in the index afterward.
- **Idle-reap exemption** (cheap): with a short `idleTimeoutMinutes`,
  assert a *streaming* session survives the idle timer while the panel
  is closed (guards the `:345` change).
- **Forward-ignore** (cheap nix-eval, sibling of
  `distro-signal-nix-eval`): assert `pi-chat` is in the effective
  `ignoredApps`.
- **`agent-vm`** (manual, visual): `key alt-slash` → screenshot (bar
  bottom-center, gap, focused) → type + Enter → screenshot (bar gone)
  → `key alt-a` → session in the tab strip. Plus the `mOn*` foreground
  contrast check the repo requires for every state.
- qmllint zero-warnings is automatic (`pi-chat-qmllint`); the new
  `QuickBar.qml` must pass with no suppressions.
- i18n: bar strings added to all 11 locale files in the same change.

## Open questions / risks

- **Headless streaming must actually work** with no window: the
  backend owns the `PiSession`, so it should, but the
  `pi-session-quick-launch` check exists specifically to prove it.
- `Mod+Slash` keysym: niri uses XKB keysyms (`slash`). Confirm the
  bind parses; the keybindings doc and the `niri-distro-binds` check
  cover regressions.
