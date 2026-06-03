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

### Iterating on GUI changes

For visual changes that the cheap headless checks can't verify
(layout, theming, panel behaviour under a real compositor), use
the headless `agent-vm` wrapper. All state lands in
`<repo>/.agent-vm/`; no env vars, no flags.

```
pueue add -- nix run .#agent-vm -- run    # background; long-running
nix run .#agent-vm -- wait                # block until sshd answers
nix run .#agent-vm -- ssh 'systemctl --user is-active niri'
nix run .#agent-vm -- key alt-a           # open the chat panel
nix run .#agent-vm -- screenshot .agent-vm/after.png
nix run .#agent-vm -- click 640 700        # left-click at framebuffer pixel
nix run .#agent-vm -- log -f              # serial console if sshd never came up
```

Read the resulting PNG back with the `read` tool to actually
see what changed. Rebuild and `agent-vm run` again after edits —
the qcow2 is throwaway.

Save artifacts under `.agent-vm/` — QEMU is sandboxed out of `/tmp`.

When screenshotting new UI, check text-vs-background contrast in
every state (hover especially): foregrounds **MUST** use the matching
`mOn…` palette entry (e.g. `Color.mOnHover` on `Color.mHover`).

#### Two VMs (remote executor)

When the change involves the **remote executor** (the panel driving a
`pi-sessiond` over WebSocket rather than spawning pi locally), use
`remote-agent-vm`. It boots both halves of the `pi-chat-remote` topology
and mirrors the same verbs with a `<server|client>` selector:

```
pueue add -- nix run .#remote-agent-vm -- run      # boots server + client
nix run .#remote-agent-vm -- wait                  # both answer ssh
nix run .#remote-agent-vm -- ssh server systemctl is-active pi-sessiond
nix run .#remote-agent-vm -- click client 970 767  # focus the panel input
nix run .#remote-agent-vm -- type client 'hello'   # type into the focused field
nix run .#remote-agent-vm -- click client 1247 767 # click send
nix run .#remote-agent-vm -- screenshot client .remote-agent-vm/reply.png
```

server = the `pi-sessiond` executor (192.0.2.1, no desktop); client = the
desktop panel (192.0.2.2), its `wsUrl` pinned at the server over a shared
QEMU socket-multicast L2 link. State lands in `.remote-agent-vm/`. Note:
niri compositor key *chords* (e.g. `alt-a`) are unreliable through synthetic
QMP input — open the panel with `ssh client '… quickshell ipc -c pi-chat
call pi-chat show'`, then drive it with `click`/`type`. Without KVM both VMs
fall back to TCG, so allow a few minutes for the desktop to come up.

## Translations

The chat panel's user-visible strings live in
`programs/pi-chat/i18n/<lang>.json`. `en.json` is the source
of truth; every other locale must carry the same keys.

When you add or rename a panel string you **MUST** update every
locale file in the same change. A new key landing only in `en.json`
ships untranslated UI to everyone else.
