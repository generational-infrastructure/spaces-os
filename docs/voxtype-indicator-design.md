# Voxtype recording indicator — design scope

A small on-screen rectangle that turns red whenever voxtype is capturing
audio, replacing the transient "voice recording started/stopped"
notifications. Status: **scoping** (not yet implemented).

## Goal

Persistent, glanceable feedback that the mic is live — the thing a
push-to-talk / streaming dictation flow actually needs — instead of a
2-second toast you might miss. When voxtype is idle the indicator is
invisible; when it is recording (or streaming) it shows a red rectangle.

## Data source — already available

voxtype writes a one-word state file and exposes it over a follow API.
The spaces voxtype config already sets `state_file = "auto"` (inherited
from upstream `config/default.toml`), so this works today with no daemon
changes:

```
$ voxtype status --follow
idle
recording
transcribing
idle
```

`voxtype status --follow` uses inotify on the state file and prints one
line per state transition (see voxtype `src/app/status.rs`). The state
vocabulary (`src/status_json.rs`):

| state          | meaning                          | indicator |
| -------------- | -------------------------------- | --------- |
| `idle`         | daemon up, not recording         | hidden    |
| `recording`    | capturing (batch / whisper)      | **red**   |
| `streaming`    | capturing (parakeet streaming)   | **red**   |
| `transcribing` | audio captured, decoding         | amber?    |
| `stopped`      | daemon not running               | hidden    |

> **Streaming nuance.** With the parakeet streaming engine now enabled on
> nv1, the active-capture state is `streaming`, not `recording`. The
> indicator must treat **both** as "mic live / red". A naive
> `state == "recording"` check would never light up under streaming.

Plain text format (above) is the simplest contract for this consumer;
`--format json` is also available but we don't need the tooltip/icons.

## Architecture — standalone Quickshell layer-shell overlay

A tiny independent Quickshell shell, run as a graphical-session user
service, drawing a wlr-layer-shell surface. **Not** a noctalia plugin:
the noctalia bar is deliberately run vanilla ("no plugin" — see
`modules/nixos/noctalia.nix` and its stale-plugin purge), so we do not
reintroduce a plugin coupling. This also keeps the indicator alive
independent of bar reloads.

This mirrors the existing `pi-chat` Quickshell precedent
(`programs/pi-chat/`, `modules/nixos/pi-chat/default.nix`) but is far
smaller: no IPC, no sessions, one window, one `Process`.

```
voxtype daemon ──writes──> state file ──inotify──> `voxtype status --follow`
                                                         │ stdout lines
                                              ┌──────────▼───────────┐
                                              │ quickshell -c        │
                                              │   voxtype-indicator  │
                                              │  Process + SplitParser│
                                              │  → state property     │
                                              │  → PanelWindow (red)  │
                                              └──────────────────────┘
```

### QML skeleton (grounded in `programs/pi-chat/QuickBar.qml` + `SignalConfirm.qml`)

```qml
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

PanelWindow {
  id: ind
  property string state: "idle"
  readonly property bool active: state === "recording" || state === "streaming"

  // Small dot, top-right corner, overlays content (no exclusive zone).
  anchors { top: true; right: true }
  margins { top: 8; right: 8 }
  exclusiveZone: 0
  implicitWidth: 12
  implicitHeight: 12
  WlrLayershell.layer: WlrLayer.Overlay      // above the bar; OSD-like
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  color: "transparent"
  visible: ind.active || ind.state === "transcribing"

  Rectangle {
    anchors.fill: parent
    radius: width / 2                              // round dot
    color: ind.active ? "#e01b24"                  // red: mic live
         : ind.state === "transcribing" ? "#e5a50a" // amber: decoding
         : "transparent"
  }

  Process {
    running: true
    command: ["voxtype", "status", "--follow"]
    stdout: SplitParser { onRead: line => ind.state = line.trim() }
  }
}
```

`Process`/`SplitParser` come from `Quickshell.Io`; the line-reading
idiom is copied from `programs/pi-chat/SignalConfirm.qml:96`.

## Files to add / change

| File | Change |
| ---- | ------ |
| `programs/voxtype-indicator/shell.qml` | new — the QML above (single file) |
| `modules/nixos/voxtype-indicator.nix` | new — materialize + `quickshell -c voxtype-indicator` user service; option `spaces.voxtype.indicator.enable` (default true) |
| `modules/nixos/voxtype.nix` | import the indicator module (it already owns the voxtype service/config + `state_file`) |
| `modules/nixos/spaces-commands.nix` | drop the `voice recording started/stopped` toasts from `voice-record-toggle` (keep the failure toast) |
| `checks/spaces-voice-record-toggle/default.nix` | update — it currently asserts the started/stopped wording, which we're removing |
| `checks/voxtype-indicator/` (new) | optional — VM/eval test: service wired, `Process` command references `voxtype status --follow`, state→visibility mapping |

The service follows pi-chat's pattern: an `ExecStartPre` materialize step
that copies the QML into `~/.config/quickshell/voxtype-indicator` with
fresh mtimes (Qt qmlcache), `Environment=PATH=…` so the bare-name
`voxtype` resolves, `partOf`/`after`/`wantedBy = graphical-session.target`.

## Notification replacement

voxtype's own toasts are already off: `[output.notification]` defaults
`on_recording_start=false`, `on_recording_stop=false`, and the voxtype
module sets `on_transcription=false`. So the only visible toasts today
are the spaces wrapper's "voice recording started/stopped"
(`spaces-commands.nix:voice-record-toggle`). Removing those + shipping
the indicator completes the "replace notifications" goal. The coupled
test (`checks/spaces-voice-record-toggle`) must be updated in the same
change.

## Edge cases

- **Daemon not running** → `voxtype status` prints `stopped`/exits; the
  `--follow` Process keeps running and emits `stopped` on death →
  indicator hidden. If the daemon restarts, inotify re-attaches (status
  watches the parent dir, not just the file).
- **Process exits** (daemon never started, config missing `state_file`) →
  consider `Process.running` auto-restart / a Timer respawn so the
  indicator recovers. `state_file` is currently guaranteed by config, so
  this is a safety net.
- **Multi-monitor** → a layer-shell `PanelWindow` binds one screen by
  default. Decide: indicator on the focused screen only, or one per
  screen (`Variants`/`Quickshell.screens`). Single-screen is fine for
  nv1.
- **Streaming flicker** → streaming may toggle `streaming`↔`transcribing`
  rapidly; both are "active-ish". Treating `transcribing` as amber (not
  hidden) avoids a flicker-to-invisible between partials.

## Decisions

1. **Placement & size** — ✅ small **round dot, top-right corner**
   (~12px, 8px margins; skeleton above).
2. **`transcribing` color** — ✅ **amber** (`#e5a50a`); red while
   capturing, amber while decoding, hidden otherwise.

## Open questions (still need a call)

3. **Multi-monitor** — focused-screen-only vs per-screen (nv1 is single,
   so default focused-only unless you want otherwise).
4. **Test depth** — light eval test (service + command wiring) vs a full
   nixosTest VM that drives a stubbed `voxtype status` and screenshots
   the surface.

## Why not …

- **Noctalia plugin/widget** — the bar is run vanilla on purpose; a
  plugin would re-couple to the era the purge script tears down, and tie
  the indicator's lifetime to bar reloads.
- **A `notify-send` with a long timeout** — still a toast, still in the
  notification stack, can't be a persistent always-visible state.
- **Patching voxtype** — unnecessary; the `status --follow` API is
  exactly the consumer contract voxtype documents for Waybar/Quickshell.
```
