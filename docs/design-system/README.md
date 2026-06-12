# Spaces OS design system

This directory holds the **handoff bundle** the user produced in Claude
Design (the conversation that walked from "make a Spaces OS design system"
through the "less rounded / declutter the panel / reframe move as runtime
control" iteration), plus its standalone PWA export and a short note
about what's been ported into the repo so far.

## Layout

- **`source/`** — the design system bundle, verbatim. The
  authoritative reference for any new UI work: token CSS, the Tabler icon
  set, React component primitives (`Icon`, `Button`, `IconButton`,
  `MachineChip`, `StatusDot`, `TextInput`, `Divider`, `Bubble`,
  `ConfirmCard`), the two interactive UI kits (`ui_kits/quickshell-panel/`,
  `ui_kits/pwa/`), the foundation specimen cards, and the `readme.md` +
  `SKILL.md` that explain the brand voice / visual rules end-to-end.
- **`source/guidelines/executor-model.md`** — the single most important
  document. The three-entity model (executor / client / chat) drives every
  multi-machine UX decision. Read this first before touching either client.
- **`source/Spaces OS - pi-chat PWA.html`** — the single self-contained
  HTML export of the PWA kit the user produced as "save as standalone
  HTML: the current design". Opens in any browser, fully offline, all
  icons + fonts inlined. Use it as the visual reference target when
  iterating on `packages/pi-web/`.

## What's already ported

The first cut implements the design system in the two surfaces that exist:

1. **Quickshell panel (`programs/pi-chat/`)** — the radii defaults in
   `Commons/Style.qml` are sharpened to **2/4/6** (from noctalia's
   8/12/16), matching the design system's crisper look. Noctalia's
   `radiusRatio`/`iRadiusRatio` still scale them at runtime, so users
   with a softer-cornered scheme keep their preference.
2. **pi-web PWA (`packages/pi-web/`)** — token CSS + Tabler icon SVGs
   are vendored at `packages/pi-web/design/` and linked from
   `index.html`. The DOM construction in `app.ts` is rewritten as a
   vanilla-TS translation of `source/ui_kits/pwa/pwa.jsx`: a chat-list
   view (`#tabs` with machine-rail rows) and a chat-view (back arrow,
   bold title, runtime control pill, design-system bubbles + confirm
   cards, mic/attach/send compose, offline banner). The reducer is
   untouched.
3. **Multi-executor fleet (`packages/pi-web/`)** — the PWA is now a
   fleet client, matching the Quickshell panel's topology. It fetches
   `/executors` from whichever daemon served it, opens one WS per peer
   (the shared `pi-pi-sessiond-token` works against all), and merges
   sessions across executors into a unified chat list — each row
   tagged with its executor's `agent-<host>.<meta.domain>` chip. The
   "+" button opens a bottom-sheet executor picker on fleets with
   more than one machine (single-executor clans skip the picker).
   The runtime pill in the chat view shows the chat's actual
   executor host, and the offline banner is per-executor (only fires
   when the active chat's WS is dead).

## What's not yet ported (and why)

- **"Where this runs" sheet / session migration.** The kit shows a
  bottom-sheet for moving an existing chat between executors. That's
  blocked on a server-side migration RPC (the chat's `session.jsonl`
  has to move to the target executor's `STATE_DIR`); the runtime pill
  is a static label until then.
- **Quickshell structural redesign.** The kit replaces the panel's
  always-on tab strip with a single chat-title + switcher + scrollable
  drawer with machine filter, and collapses the five header icons into
  one overflow menu. That is a deliberate next-PR — it's a substantial
  rewrite of `programs/pi-chat/Panel.qml` with its own test surface,
  and the radii sharpening already lands the most visible part of the
  visual story without it.
- **Webfonts.** `source/tokens/fonts.css` imports Inter + JetBrains
  Mono from Google Fonts. The pi-web port skips that import because
  the e2e nix sandbox is offline; the typography token stack falls
  back to `system-ui` / `ui-monospace` cleanly. The Quickshell panel
  picks up the real families because they're installed system fonts
  on the target NixOS configuration. To self-host webfonts for the
  PWA, drop `.woff2` binaries under `packages/pi-web/design/fonts/`
  and add the corresponding `@font-face` rules in a new `fonts.css`.
