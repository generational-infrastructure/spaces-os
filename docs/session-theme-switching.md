# Dark/light theme switching across the Spaces session

Research note (design only — nothing here is implemented). Scope: how a
single dark↔light switch should propagate to the three things that paint
the Spaces desktop — the **noctalia bar**, the **pi-chat panel**, and the
new **wl-harmonograph background** (`modules/nixos/harmonograph.nix`).

## TL;DR recommendation

**noctalia is already the single source of truth.** It owns the palette,
writes the resolved colours to `colors.json`, and the pi-chat panel
already mirrors that file live. The only component that does *not* follow
yet is the wl-harmonograph background. So:

1. Drive the switch through **noctalia's existing `darkMode` IPC** (wrap
   it as a `spaces-theme` command + a niri keybind; optionally surface
   noctalia's built-in `DarkMode` bar widget).
2. Leave **pi-chat untouched** — `Color.qml`/`Style.qml` already watch
   `colors.json`/`settings.json` and recolour on every switch.
3. Add a small **`colors.json` → wl-harmonograph bridge**: a per-user
   path unit that re-derives `HARMONOGRAPH_FG`/`HARMONOGRAPH_BG` from
   `colors.json` and restarts the background service. This makes the
   background track *any* scheme change (dark/light, a different
   predefined scheme, or wallpaper-derived colours), not just dark/light.

This keeps one authority (noctalia) and reuses the exact contract the
panel already consumes, instead of inventing a parallel palette.

## How theming works today

### noctalia — the palette authority

noctalia-shell resolves a Material-3 palette and writes it to
`${NOCTALIA_CONFIG_DIR:-$XDG_CONFIG_HOME/noctalia}/colors.json`. The
relevant knobs live in `~/.config/noctalia/settings.json`
(from `pkgs.noctalia-shell`, v4.7.x source in the Nix store):

- `colorSchemes.darkMode` (bool, default `true`) — dark vs light variant
  (`Services/Theming/ColorSchemeService.qml:30,199-207`;
  `Commons/Settings.qml:739`).
- `colorSchemes.predefinedScheme` (string, e.g. "Gruvbox", "Tokyo-Night")
  — which scheme (`Commons/Settings.qml:738`).
- `colorSchemes.useWallpaperColors` (bool) — derive from the wallpaper
  instead (`Services/Theming/ColorSchemeService.qml:38`).
- `colorSchemes.schedulingMode` ("off"|"location"|"manual") — automatic
  sunrise/sunset switching (`Commons/Settings.qml:740`).

Any change to these re-runs `writeColorsToDisk(...)`, which rewrites
`colors.json` with the selected variant
(`Services/Theming/ColorSchemeService.qml:36-42,266-291`). noctalia
exposes runtime IPC for this:

```sh
quickshell ipc -c noctalia call darkMode toggle      # or setDark / setLight
quickshell ipc -c noctalia call colorScheme set "Gruvbox"
```

(`Services/Control/IPCService.qml:454-464,488-491`.) It also ships a
clickable `DarkMode` bar widget (`Modules/Bar/Widgets/DarkMode.qml:39`).

In this repo the managed `settings.json` pins **only** `bar.position` and
`bar.widgets.center` and deep-merges them in
(`modules/nixos/noctalia.nix:27-33,214`); **no theme key is pinned**, so
the user's dark/light/scheme choice is theirs and survives rebuilds.

### pi-chat — already mirrors noctalia, live

The panel reads the *same* `colors.json` noctalia writes, resolving the
config dir identically and watching the file:

- `programs/pi-chat/Commons/Color.qml:49-61` — `FileView` on
  `…/noctalia/colors.json`, `watchChanges: true`, reload on change; the
  Material-3 keys it exposes (`mPrimary`, `mSurface`, …) mirror
  noctalia's `colors.json` schema (`:63-83`).
- `programs/pi-chat/Commons/Style.qml:84-92` — same pattern on
  `settings.json` for radii/spacing ratios.

The dedicated component check `checks/pi-session-noctalia-theme` already
asserts the panel both loads from `colors.json` and **live-updates on a
light/dark switch**. So a dark↔light flip in noctalia recolours the panel
with zero extra wiring — this leg is done.

### wl-harmonograph — does NOT follow yet

The background reads its colours from two environment variables **once at
startup** (`colors_from_env()` in the input's `src/main.rs:67,79`):
`HARMONOGRAPH_FG` (comma-separated hex, cycled) and `HARMONOGRAPH_BG`
(single hex). There is no file watch and no live reload. The new module
surfaces these as `services.spaces.background.foreground` /
`.background` (`modules/nixos/harmonograph.nix`), defaulting to
gruvbox-dark. To follow a switch the service must get new env values and
**restart**.

## Options, ranked

### A. Single source of truth (noctalia) + colors.json→background bridge — **recommended**

- **Switch:** `quickshell ipc -c noctalia call darkMode toggle`, wrapped as
  a `spaces-theme` command (the `mkCommand` pattern in
  `modules/nixos/spaces-commands.nix:30-57`) bound to a niri key (mirror
  `Mod+Shift+N` bar-reload at `modules/nixos/niri.nix:68`), and/or
  `{ id = "DarkMode"; }` added to the managed center/right widget list.
- **Bar:** noctalia recolours itself.
- **Panel:** unchanged — tracks `colors.json` live.
- **Background:** a per-user `systemd.user.path` unit watches
  `~/.config/noctalia/colors.json`; on change a small script maps the
  palette to env (e.g. `HARMONOGRAPH_BG = mSurface`, `HARMONOGRAPH_FG =
  [mPrimary, mSecondary, mTertiary, mPrimary…]`), writes an
  `EnvironmentFile`, and `systemctl --user restart wl-harmonograph`. The
  module's `foreground`/`background` options become the fallback when
  `colors.json` is absent.
- **Pros:** one authority; the background tracks *any* recolour (dark/
  light, scheme swap, wallpaper colours), exactly like the panel; reuses
  the proven `colors.json` contract. **Cons:** the background restarts per
  switch (env-only ⇒ the figure re-seeds — arguably a feature); one new
  watcher unit.
- **Files:** `modules/nixos/harmonograph.nix` (bridge unit + script),
  `modules/nixos/spaces-commands.nix` (`spaces-theme`),
  `modules/nixos/niri.nix` (keybind), optionally
  `modules/nixos/noctalia.nix` (pin a default scheme/`darkMode` while
  leaving it user-overridable, and/or the `DarkMode` widget). pi-chat: none.

### B. One `spaces-theme` command flips all three explicitly

- A `spaces-theme dark|light|toggle` wrapper calls the noctalia `darkMode`
  IPC **and** rewrites the wl-harmonograph env from a fixed dark/light
  colour pair declared on the module, then restarts the service. Panel
  still auto-follows `colors.json`.
- **Pros:** no file-watcher; fully deterministic; one command. **Cons:**
  the background uses a hardcoded dark/light pair, so it ignores scheme/
  wallpaper changes; "what dark means" is defined twice (noctalia scheme +
  the harmonograph pair). Good **minimal** step if the watcher feels heavy.

### C. Per-component, no coordination — rejected

Toggle noctalia by hand, leave the rest. The panel happens to follow, but
the background goes stale and there is no single switch. Not viable as a
default.

## The one wrinkle

wl-harmonograph reloads colours only at process start, so every option
restarts it on a switch. An upstream change to watch `HARMONOGRAPH_*` (or
a config file) and re-seed in place would let the background recolour
without a restart; until then, restart-on-change is the mechanism. This is
the only reason the background can't be as seamless as the panel.
