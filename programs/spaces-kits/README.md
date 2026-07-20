# spaces-kits (QML)

Native QtQuick / Quickshell port of the Spaces OS **UI kits** — the two
flagship reference screens, built on the Kin design system:

- **Files** — a Finder-style file browser: rail, search + Create, grid/list
  switch, and sectioned 6-up tiles (Recents / Shared / Favourites).
- **Arlo home** — the "Space" desktop: OS top bar (Clan switcher, live
  presence, quick settings), a centred conversation with the Arlo orb +
  tagline, suggested prompts, and the ask bar.

This is the desktop-native counterpart to the web kit under
`packages/spaces-kits` (vanilla TS). Same design language, rendered with the
real Inter / DM Mono faces the Spaces OS bundle installs.

## Layout

- `Commons/` — `Theme` (Kin tokens: palette, type, radii, motion) and `Icons`
  (the line-icon glyph set), as singletons (mirrors pi-chat's `Commons`).
- `Components/` — the design-system primitives as a `qs.Components` module:
  `KinIcon`, `KinButton`, `KinIconButton`, `KinInput`, `KinSegmentedControl`,
  `KinBadge`, `KinAvatar`, `ArloOrb`, `KinSidebarItem`, `KinFileTile`. Icons
  bake their stroke colour into the SVG and draw it as a data-URI Image (the
  same trick as pi-chat's `NIcon`).
- `FilesApp.qml`, `ArloHome.qml` — the screens, as plain `Item`s so they
  compose into a Quickshell window or a bare QtQuick preview window.
- `shell.qml` — the Quickshell entry (two `FloatingWindow`s).

## Run

```sh
quickshell -p programs/spaces-kits        # from a checkout
spaces-kits                               # the packaged launcher (packages/spaces-kits-qml)
```

`nix build .#spaces-kits-qml` builds the launcher + a desktop entry.
`nix build .#checks.<system>.spaces-kits-qmllint` runs the strict qmllint gate.

## Fidelity notes

- The Arlo robot render and Clan portraits use the design system's own
  fallbacks (the gradient orb, tinted-initial avatars). Point `ArloOrb` /
  `KinAvatar` at real images for full fidelity.
- Fonts are Inter / DM Mono — installed system-wide by `nixosModules.spaces`.
