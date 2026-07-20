# spaces-kits

The Spaces OS flagship **UI kits** rendered as real, browsable screens, built
on the Kin / Spaces OS design system:

- **Files** (`/files/`) — a Finder-style file browser: left rail, search +
  Create top bar, grid/list switch, and sectioned tiles (Recents / Shared /
  Favourites). Type in search to filter live; toggle grid↔list.
- **Arlo home** (`/home/`) — the "Space" desktop where you talk to **Arlo**,
  your private local agent: OS top bar (Clan switcher, live presence, quick
  settings), a centred conversation with the orb + tagline, suggested prompts,
  and the ask bar. Send a message and Arlo replies with context-aware text.

## How it's built

Vanilla TypeScript bundled by [Bun](https://bun.sh) — zero npm deps, fully
offline, the same ethos as `packages/pi-web`. The screens are a DOM-building
translation of the design system's React/JSX source:

- `lib/` — the ported design-system primitives (`Button`, `IconButton`,
  `Input`, `SegmentedControl`, `Badge`, `Avatar`, `ArloOrb`, `SidebarItem`,
  `FileTile`), an `icon()` line-icon set, and a tiny `h()` hyperscript that
  consumes the same camelCase style objects the JSX used.
- `files/main.ts`, `home/main.ts` — the two composed screens.
- `design/` — the **native** Kin token CSS (`--clan-*`, `--ink-*`, `--kin-*`,
  `--fs-*`, `--radius-*`) plus the Kin mark. Imported via `design/styles.css`.

Build it with `nix build .#spaces-kits`; open `result/index.html` (serve the
directory so the absolute `/design/…` links resolve).

## Notes / fidelity

- **Fonts**: Inter Tight / Inter / DM Mono aren't webfont-imported (the nix
  build is offline). The stacks fall back to `system-ui` / `ui-monospace`; on
  the real Spaces OS target those are installed system fonts.
- **Brand imagery**: Arlo's render and the Clan portraits are bespoke clay
  assets in the Figma file. Here the design system's own fallbacks stand in
  (the iridescent gradient orb, tinted-initial avatars). Drop real images in
  `design/assets/` and pass a `src` to `ArloOrb` / `Avatar` for full fidelity.
- **Relationship to pi-web**: `pi-web` is the chat PWA, re-skinned to this same
  Kin design language via its `--m-*` role layer. These kits author against the
  native Kin token names directly.
