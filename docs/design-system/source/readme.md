# Spaces OS Design System

The design system for **Spaces OS** — an AI-agent desktop integration for
NixOS. You run your own LLM agents on your own machines and talk to them
from a chat surface summoned by a global keybind, with full sandboxing
and an extensible skill system.

This repo is the shared visual + interaction language across the two
**clients** that surface those agents:

- **pi-chat panel** — a Quickshell (`wlr-layer-shell`) sidepanel docked
  to the desktop edge, summoned with `Mod+A`. Does **not** appear in
  alt-tab; coexists with any Wayland shell. The original product UI.
- **pi-chat PWA** — a phone/web client that attaches to the same machines
  remotely, so a task you start at your desk continues in your pocket.

> **The product mental model — read this first.** A chat is a long-running
> *process on a machine* (an "executor"); a client is just a window onto
> it. This single idea drives the whole multi-machine UX (which machine a
> chat runs on, reachability, moving a chat, cross-device continuity). The
> full model lives in **[`guidelines/executor-model.md`](guidelines/executor-model.md)** —
> read it before touching either client.

## Sources

Everything here is reverse-engineered from the real product code, not
guessed. Explore these to do a better job designing for Spaces OS:

- **GitHub — `generational-infrastructure/spaces-os`**
  <https://github.com/generational-infrastructure/spaces-os>
  - `programs/pi-chat/` — the Quickshell UI (QML). Source of truth for
    everything visual:
    - `Commons/Color.qml` — the M3 palette ("Noctalia-default dark")
    - `Commons/Style.qml` — spacing / radii / font / motion tokens
    - `Widgets/N*.qml` — the primitive widgets (NButton, NIconButton,
      NText, NTextInput, NComboBox, NIcon, NDivider, …)
    - `Panel.qml` — the full sidepanel (header, session tabs, search,
      message list, compose)
    - `Bubble.qml` — chat rows, confirm & prompt cards
    - `QuickBar.qml` — the `Mod+/` background-agent launcher
    - `i18n/en.json` — canonical UI copy
    - `icons/` — the vendored Tabler icon set (MIT)
  - `README.md`, `docs/` — product behaviour, keybindings, remote-pi design.

The live panel re-themes itself at runtime from the user's **noctalia**
scheme (`colors.json` / `settings.json`). The tokens captured here are the
**defaults** shipped when no scheme is present ("Noctalia-default dark").

---

## Content fundamentals

How Spaces OS writes. The voice is **terse, technical, lower-case-leaning,
and trustworthy** — closer to a well-labelled terminal than a consumer
chat app.

- **Casing.** Sentence case for actions and titles (`Start a new chat
  session`, `Attach image`). **lowercase** for live status words —
  `connected`, `daemon offline`, `thinking…`, `ready`, `now`. Hostnames
  and model ids are always lowercase **monospace** (`kiwi`,
  `qwen2.5-coder:14b`).
- **Length.** Short. Buttons are one word where possible — `Send`,
  `Allow`, `Deny`, `Wipe`, `Cancel`, `Submit`. Tooltips are imperative
  fragments — `Switch the model used for new replies`, `Restart
  conversation (clear context)`, `Voice to text`.
- **Person.** Second person, usually implied: `Message {name}…`,
  `Search messages…`. The agent is addressed by its peer name (default
  `Chat`). Avoid "I" for the assistant in chrome copy.
- **Tense / progress.** Trailing ellipsis for in-flight states —
  `thinking…`, `Waiting for daemon…`, `loading models…`, `Moving to
  studio…`.
- **Security-first phrasing.** When the agent wants to act, the copy
  states exactly what will happen and asks plainly: `Run shell command?`
  with the literal command shown. Destructive actions spell out the
  consequence: `Wipe every stored memory item across all chats? This
  cannot be undone.` Memory capture warns: *"Anything you type can be
  picked up by the extractor — flip the toggle off before pasting
  secrets."*
- **Emoji & glyphs.** No decorative emoji. The only glyphs are
  *functional* delivery/outcome marks — `🕓` pending, `✓` sent, `✓✓`
  read, `⚠` retry; `✓ allowed` / `✗ denied`. Treat these as status
  icons, not personality.
- **No.** No exclamation marks, no marketing adjectives, no "Oops!",
  no hype. Calm and precise.

Sample strings (verbatim from `i18n/en.json`): `connected` ·
`daemon offline` · `{count} new` · `Message {name}…` ·
`Earlier conversation may still be in the agent's context — type to
continue.` · `Launch an agent…  ( / for options )` · `↵ launch`.

---

## Visual foundations

**Overall vibe:** dark-first, flat, dense, terminal-adjacent. Deep indigo
surfaces with a few bright pastel accents. Calm, precise, a little
hacker. Identity is carried by **colour + monospace**, never by imagery.

### Colour
- **Surfaces** are a deep near-black indigo: base `#070722`, raised
  `#11112d`. They separate by **fill + a 1px indigo outline (`#21215f`)**,
  never by drop shadow.
- **Accents** are soft M3 pastels, each with a deep-navy ink (`#0e0e43`)
  for text on top: **chartreuse `#fff59b`** (primary — own messages, the
  main CTA, the active machine), **periwinkle `#a9aefe`** (secondary —
  links, focus ring on the compose box), **mint `#9bfece`** (tertiary —
  success, "online"/reachable, hover fills), **hot-pink `#fd4663`**
  (error — failures, "offline", the recording state).
- **Text** is a near-white lilac `#f3edf7`; muted text is a lavender-grey
  `#7c80b4`.
- **Dark-first, themeable.** The product tracks the user's noctalia
  colour scheme live. Design against the tokens, not the hexes, so a
  re-theme just works.

### Type
- **Inter** for all UI. **JetBrains Mono** for code, shell commands, and —
  importantly — **machine hostnames and model ids** (mono signals "this
  is a literal identifier").
- One workhorse weight: **Medium (500)**, with **Bold (700)** for
  emphasis (peer name, card titles, the active tab).
- Sizes are **small and dense** — the panel runs 9–16pt. The web scale
  re-expresses these as 12 → 21px, with larger display sizes (28/40/56)
  reserved for PWA headers.

### Spacing, radii, borders
- **Tight** spacing scale: 2 / 4 / 6 / 9 / 13px base (extended to
  18/26/40 for web layouts). This is a desktop panel, not an airy page.
- **Radii:** 8px (chips/quotes), 12px (bubbles, cards, tabs, banners),
  16px (buttons, inputs, combos, pills), 999px (status pills).
- **Borders:** a single 1px outline does the structural work everywhere.

### Elevation & motion
- **Flat.** No content shadows. The only shadow is a soft ambient lift
  for floating popups / bottom sheets over the panel.
- **Motion is fast and minimal:** 150ms `InOutQuad` colour transitions on
  hover/focus, a 100ms opacity fade for hover-revealed controls, and a
  soft **pulse** for the "working" state. No bounce, no decorative loops;
  honour `prefers-reduced-motion`.

### States
- **Hover:** controls flip to the **mint hover fill** with navy ink
  (`--m-hover` / `--m-on-hover`); pill buttons brighten ~1.1×.
- **Focus:** the input outline turns an accent colour — **primary** for
  search/inline inputs, **periwinkle** for the multiline compose box.
- **Disabled:** opacity 0.6, no fill change.

### Bubbles & cards (the signature surface)
- **Author is encoded by alignment + fill, not avatars.** Own messages:
  chartreuse fill, navy ink, right-aligned, no border. Peer/assistant:
  surface-variant fill, 1px outline, left-aligned. Notifications: centred
  faded text, no bubble. Thinking: small italic faded text, no bubble.
- **Delivery ladder** under own messages (`🕓 → ✓ → ✓✓`, `⚠` on retry);
  optional `t/s` footer under assistant messages.
- **Confirm / prompt cards** are surface-variant with a **state-coloured
  border**: chartreuse (pending) → mint (allowed/submitted) → pink
  (denied/cancelled). They stay as a permanent audit line after answering.

### Transparency / blur
- The layer-shell panel and the desktop top bar use a **translucent
  surface + backdrop blur**. Overlays (run-on picker, move sheet) dim the
  surface behind with a dark scrim.

### Machine identity (product-specific)
- Each machine ("executor") gets **one stable palette colour** + its
  hostname. **Colour answers *which* machine; a status dot answers *can I
  reach it*** (mint online · pink offline). The same colour follows a
  machine across tabs, headers, list rows, and the fleet roster. See
  `guidelines/executor-model.md`.

---

## Iconography

- **Tabler Icons**, *outline* style — 24px grid, **2px stroke**, round
  caps/joins, drawn in `currentColor` (recolour by setting `color`). MIT
  licensed. The exact set is **vendored** in `assets/icons/` (lifted
  verbatim from `programs/pi-chat/icons`). Add an icon by dropping its SVG
  in; recolour it by inheriting `color`.
- The product renders icons from these SVG files (the panel's `NIcon`
  inlines and recolours them). This system ships an **`Icon`** React
  component with the same set embedded, plus a CSS-mask / inline-SVG
  pattern in the cards.
- **No icon font. No decorative emoji.** The only non-icon glyphs are the
  functional delivery/outcome marks (`✓ ✓✓ 🕓 ⚠`, `✗`).
- **Common icons & their meaning:** `message-chatbot` (header / Chats
  tab), `sparkles` (the launcher), `send`, `paperclip` (attach),
  `microphone` / `microphone-off` (voice), `brain` ↔ `database-off`
  (long-term memory on/off), `eraser` (wipe memory), `rotate` (restart /
  relayed), `search`, `dots-vertical` (options / move), `plus` (new chat),
  `key` / `edit` (credential & value prompts), `gauge` (inference speed /
  Machines tab), `eye` / `eye-off` (show/hide thinking), `corner-down-right`
  (reply / quote / continuity), `check` / `x`, `chevron-up` / `-down`.
- Machine identity is conveyed by **colour, not an icon**.

> **Font note.** Inter and JetBrains Mono are the *exact* families the
> product uses (`Settings.qml`), loaded here from Google Fonts (their
> upstream home) via `tokens/fonts.css` — this is not a substitution. For
> a fully offline bundle, drop `.woff2` files in `assets/fonts/` and swap
> the `@import` for local `@font-face` rules.

---

## Index / manifest

```
styles.css                     ← global entry point (consumers link this; @import-only)
tokens/
  colors.css                   ← M3 palette + semantic aliases + overlays
  typography.css               ← families, type scale, weights
  spacing.css                  ← spacing, radii, borders, elevation, motion
  fonts.css                    ← Inter + JetBrains Mono (Google Fonts @import)
components/
  core/      Icon · Button · IconButton · MachineChip · StatusDot · TextInput · Divider
  chat/      Bubble · ConfirmCard
  (each component: <Name>.jsx + <Name>.d.ts + <Name>.prompt.md; one *.card.html per dir)
guidelines/
  executor-model.md            ← THE multi-machine mental model (read first)
  cards/                       ← foundation specimen cards (Design System tab)
ui_kits/
  shared/kit.jsx               ← shared self-contained kit components (window.SOS)
  quickshell-panel/            ← the desktop sidepanel — index.html + panel.jsx
  pwa/                         ← the phone client — index.html + pwa.jsx + ios-frame.jsx
assets/
  icons/                       ← vendored Tabler outline SVGs (+ LICENSE)
SKILL.md                       ← Agent-Skills entry point for downloaded use
```

**Components** (reusable primitives, consumed via `window.<Namespace>`
once compiled — run `check_design_system` for the exact namespace):
`Icon`, `Button`, `IconButton`, `MachineChip`, `StatusDot`, `TextInput`,
`Divider`, `Bubble`, `ConfirmCard`.

**UI kits** (full interactive recreations): the **Quickshell sidepanel**
and the **pi-chat PWA** — both machine-aware, with the run-on picker, the
move flow, offline/read-only states, and cross-device confirms.
