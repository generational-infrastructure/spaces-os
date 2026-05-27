# Agent guidelines

## Development style

Follow red-green-refactor TDD:

1. **Red** — write the test first, run it, watch it fail for the
   right reason. A test that fails because the symbol is undefined
   does **not** count; the assertion you care about must be reached.
2. **Green** — write the minimum code to make it pass.
3. **Refactor** — clean up with the test still green.

## Testing

Two flavours of test live in `checks/`:

- **Cheap focused tests** (`checks/pi-session-*`, `checks/pi-rpc-*`,
  …): headless quickshell against a small `shell.qml`. ~3–10s.
- **The full-system VM test** (`checks/test-machine.nix`): boots
  greetd → niri → pi-chat panel. ~60–120s plus QEMU overhead.

You **SHOULD** add per-feature behaviour coverage as a cheap focused
test. Look at the existing siblings for the pattern — blueprint
auto-discovers anything under `checks/`.

You **MUST NOT** bolt new subtests onto `checks/test-machine.nix`
just because it already runs the chat shell. The VM test is for
cross-subsystem wiring; extend it only when the behaviour genuinely
depends on the full boot path.

## Translations

The chat panel's user-visible strings live in
`programs/pi-chat/i18n/<lang>.json`. `en.json` is the source
of truth; every other locale must carry the same keys.

When you add or rename a panel string you **MUST** update every
locale file in the same change. A new key landing only in `en.json`
ships untranslated UI to everyone else.
