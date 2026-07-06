# Keyboard shortcuts

Spaces's full-desktop module (`nixosModules.spaces`) wires a small set
of opinionated keybinds into niri on top of the upstream defaults.
This page documents both. `Mod` is **Super** on bare metal and **Alt**
inside the VM test runner (see `services.spaces.niri.modKey`).

All spaces binds are declared once in
[`modules/keybinds.nix`](../modules/keybinds.nix) (the model) and
rendered by two backends:

- [`modules/nixos/niri.nix`](../modules/nixos/niri.nix) injects the
  model's spawn binds into niri's upstream `default-config.kdl`;
- [`modules/home/sway.nix`](../modules/home/sway.nix) renders the full
  model as home-manager sway keybindings.

The tables below are generated from that model, and
`checks/niri-spaces-binds` fails if any model bind is missing here —
adding a bind means one model entry plus one row below.

## Spaces-specific binds (niri)

The model's spawn binds, injected into niri's config by
[`modules/nixos/niri.nix`](../modules/nixos/niri.nix). Each spawns a
notifying `spaces-*` wrapper from
[`modules/nixos/spaces-commands.nix`](../modules/nixos/spaces-commands.nix).

| Shortcut | Action |
|---|---|
| `Mod+A` | Toggle AI Chat — the pi-chat panel |
| `Mod+/` | Quick-launch Agent — type a prompt + Enter fires an agent in the background (the chat panel stays closed; a desktop notification fires on completion). Continue the session later via `Mod+A`. |
| `Mod+S` | Voice to Text — toggle voice-to-text recording (voxtype) |
| `Mod+Shift+N` | Reload bar — restart `noctalia-shell.service` after a rebuild without a logout |
| `Mod+Shift+A` | Reload pi-chat — re-materialize the panel's QML and restart it, picking up the latest rebuild without a logout |
| `Mod+L` | Lock screen (swaylock) |
| `Ctrl+Alt+L` | Lock screen (swaylock) — same as `Mod+L`, works with any modKey |

`Mod+L` overrides the upstream `focus-column-right` binding. The same
action is still available on `Mod+Right`.

These chords use the model's `SMod` token (the spaces command
modifier): under sway it may be relocated independently via
`spaces.commandModifier`; niri collapses it to `Mod`.

## Full model (sway)

Everything [`modules/home/sway.nix`](../modules/home/sway.nix) renders:
the spawn binds above (except `Mod+Shift+A`, which is niri-only) plus
window management and workspaces.

| Shortcut | Action |
|---|---|
| `Mod+Return` | Terminal |
| `Mod+Left` / `Mod+Down` / `Mod+Up` / `Mod+Right` | Focus left / down / up / right |
| `Mod+Shift+H` / `Mod+Shift+J` / `Mod+Shift+K` / `Mod+Shift+L` | Move left / down / up / right |
| `Mod+Shift+Q` | Close window |
| `Mod+F` | Fullscreen |
| `Mod+Shift+Space` | Toggle floating |
| `Mod+Shift+R` | Reload config |
| `Mod+Shift+E` | Exit compositor |
| `Mod+1` `Mod+2` `Mod+3` `Mod+4` `Mod+5` `Mod+6` `Mod+7` `Mod+8` `Mod+9` | Workspace 1–9 |
| `Mod+Shift+1` `Mod+Shift+2` `Mod+Shift+3` `Mod+Shift+4` `Mod+Shift+5` `Mod+Shift+6` `Mod+Shift+7` `Mod+Shift+8` `Mod+Shift+9` | Move to workspace 1–9 |

## Inherited niri defaults

The shortcuts below come from niri's upstream `default-config.kdl`
and are unchanged by spaces. This is a curated summary; press
`Mod+Shift+/` (i.e. `Mod+?`) at any time to see the live hotkey
overlay.

### Programs

| Shortcut | Action |
|---|---|
| `Mod+T` | Open a terminal (alacritty) |
| `Mod+D` | Run an application (fuzzel) |
| `Super+Alt+L` | Lock the screen (swaylock) — upstream default, kept for muscle memory |
| `Super+Alt+S` | Toggle the screen reader (orca) |

### Window & column focus

| Shortcut | Action |
|---|---|
| `Mod+Left` / `Mod+H` | Focus column to the left |
| `Mod+Right` / `Mod+L` | *(See note above — `Mod+L` is remapped to lock; use `Mod+Right` or `Mod+H` / vim keys.)* |
| `Mod+Down` / `Mod+J` | Focus window below |
| `Mod+Up` / `Mod+K` | Focus window above |
| `Mod+Home` / `Mod+End` | Focus first / last column |
| `Mod+Page_Down` / `Mod+U` | Focus workspace below |
| `Mod+Page_Up` / `Mod+I` | Focus workspace above |
| `Mod+Shift+{Left,Down,Up,Right}` / `Mod+Shift+{H,J,K,L}` | Focus monitor in that direction |
| `Mod+O` | Toggle the workspace overview |
| `Mod+Q` | Close focused window |

### Window & column movement

| Shortcut | Action |
|---|---|
| `Mod+Ctrl+{Left,Down,Up,Right}` / `Mod+Ctrl+{H,J,K,L}` | Move column / window in that direction |
| `Mod+Ctrl+Home` / `Mod+Ctrl+End` | Move column to first / last |
| `Mod+Ctrl+Page_Down` / `Mod+Ctrl+U` | Move column to workspace below |
| `Mod+Ctrl+Page_Up` / `Mod+Ctrl+I` | Move column to workspace above |
| `Mod+Shift+Ctrl+{Left,Down,Up,Right}` / `Mod+Shift+Ctrl+{H,J,K,L}` | Move column to monitor in that direction |
| `Mod+Shift+Page_Down` / `Mod+Shift+Page_Up` | Move whole workspace down / up |

### Media & hardware keys

| Shortcut | Action |
|---|---|
| `XF86AudioRaiseVolume` / `XF86AudioLowerVolume` | Adjust default sink volume |
| `XF86AudioMute` | Mute default sink |
| `XF86AudioMicMute` | Mute default source |
| `XF86AudioPlay` / `XF86AudioStop` | Play-pause / stop (MPRIS via playerctl) |
| `XF86AudioPrev` / `XF86AudioNext` | Previous / next track |
| `XF86MonBrightnessUp` / `XF86MonBrightnessDown` | Adjust backlight ±10% |

### Help

| Shortcut | Action |
|---|---|
| `Mod+Shift+/` | Show the hotkey overlay (live list of all binds) |

For everything else (resizing, screenshots, tabbed-column toggles, …)
see the upstream
[`default-config.kdl`](https://github.com/YaLTeR/niri/blob/main/resources/default-config.kdl).
