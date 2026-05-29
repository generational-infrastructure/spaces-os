# Keyboard shortcuts

Distro's full-desktop module (`nixosModules.distro`) wires a small set
of opinionated keybinds into niri on top of the upstream defaults.
This page documents both. `Mod` is **Super** on bare metal and **Alt**
inside the VM test runner (see `services.distro.niri.modKey`).

## Distro-specific binds

Added in [`modules/nixos/niri.nix`](../modules/nixos/niri.nix).

| Shortcut | Action |
|---|---|
| `Mod+A` | Toggle the pi-chat AI panel |
| `Mod+S` | Toggle voice-to-text recording (voxtype) |
| `Mod+L` | Lock the screen (swaylock) |
| `Ctrl+Alt+L` | Lock the screen (swaylock) — same as `Mod+L`, works with any modKey |
| `Mod+Shift+N` | Restart `noctalia-shell.service` (reload the bar after rebuild without a logout) |
| `Mod+Shift+A` | Reload the pi-chat agent: re-materialize the panel's QML and restart it, picking up the latest rebuild without a logout |

`Mod+L` overrides the upstream `focus-column-right` binding. The same
action is still available on `Mod+Right`.

## Inherited niri defaults

The shortcuts below come from niri's upstream `default-config.kdl`
and are unchanged by distro. This is a curated summary; press
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
