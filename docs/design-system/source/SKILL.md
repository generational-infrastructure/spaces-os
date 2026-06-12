---
name: spaces-os-design
description: Use this skill to generate well-branded interfaces and assets for Spaces OS (the NixOS AI-agent desktop integration — the pi-chat Quickshell sidepanel and the pi-chat PWA), either for production or throwaway prototypes/mocks. Contains essential design guidelines, colors, type, fonts, the Tabler icon set, the multi-machine UX model, and reusable UI components for prototyping.
user-invocable: true
---

Read the `readme.md` file within this skill first — it is the design guide
and manifest. Then explore the other available files as needed.

Essential reading before designing either client:
- `guidelines/executor-model.md` — the multi-machine mental model (a chat
  is a process on a "machine"/executor; clients are windows onto it). This
  drives the whole UX: which machine a chat runs on, reachability, moving
  a chat, and cross-device continuity. Get this right.

Where things live:
- `styles.css` — the single stylesheet to link; it `@import`s all tokens.
- `tokens/` — colours (Noctalia-default dark M3 palette), type (Inter +
  JetBrains Mono), spacing/radii/motion.
- `assets/icons/` — the vendored Tabler outline set (2px stroke,
  currentColor). Copy these out; don't hand-draw icons or use emoji.
- `components/` — reusable React primitives (Icon, Button, IconButton,
  MachineChip, StatusDot, TextInput, Divider, Bubble, ConfirmCard). Each
  has a `.prompt.md` with usage.
- `ui_kits/` — full interactive recreations of the two clients; copy
  `ui_kits/shared/kit.jsx` for self-contained component implementations.

How to work:
- If creating visual artifacts (slides, mocks, throwaway prototypes),
  copy the assets you need out and produce static/standalone HTML files
  for the user to view. Drive everything from the token CSS variables.
- If working on production code, copy assets and absorb the rules here to
  become an expert in designing with this brand.
- Honour the voice (terse, lowercase status words, monospace hostnames,
  security-first phrasing, no decorative emoji) and the visual foundations
  (dark/flat, 1px outlines not shadows, fast minimal motion, machine =
  colour + status dot).

If the user invokes this skill without other guidance, ask what they want
to build or design, ask a few focused questions, and act as an expert
designer who outputs HTML artifacts _or_ production code, depending on the
need.
