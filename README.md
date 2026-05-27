# distro

AI agent desktop integration for NixOS. Chat with a local AI agent
from a layer-shell panel summoned by a global keybind, with full
sandboxing and an extensible skill system.

The stack: [niri](https://github.com/YaLTeR/niri) (Wayland compositor,
optional) + [Quickshell](https://quickshell.org) (panel surface) +
[pi](https://github.com/mariozechner/pi-mono) (coding agent) +
[llama-swap](https://github.com/mostlygeek/llama-swap) (local LLM
server) + voice-to-text.

## Supported compositors

The chat panel uses [`wlr-layer-shell`](https://wayland.app/protocols/wlr-layer-shell-unstable-v1)
so the surface is anchored to the screen edge and **does not appear in
alt-tab**. That rules out GNOME (Mutter has no `wlr-layer-shell`).
Tested compositors: **niri, sway, Hyprland, river, KDE Plasma 6
(Wayland)**.

The panel coexists with any Wayland desktop shell — including noctalia
if you happen to run one — because it ships as its own `quickshell -c
pi-chat` instance with its own IPC namespace.

## Two ways to use it

| Integration | What you get | You provide |
|---|---|---|
| **Full desktop** | Niri compositor + pi-chat panel + AI agent + local LLM | A NixOS machine |
| **Panel only** | pi-chat panel + AI agent + local LLM | Your own Wayland compositor (sway/Hyprland/KDE/…) |

## Binary Cache

Configure the [numtide binary cache](https://cache.numtide.com/index.html) to
avoid building dependencies from source.

## Setup

### 1. Full desktop

Import `nixosModules.distro` for the complete experience: niri
compositor, pi-chat Quickshell panel, AI agent, local LLM server. The
module enables the AI agent and greetd auto-login into niri by
default.

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-unstable";
    distro.url = "github:generational-infrastructure/distro";
  };

  outputs = { nixpkgs, distro, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        distro.nixosModules.distro
        {
          # Override the default greetd auto-login user.
          services.greetd.settings.default_session.user = "alice";
        }
      ];
    };
  };
}
```

This gives you:
- **Mod+T** — terminal (alacritty)
- **Mod+D** — app launcher (fuzzel)
- **Mod+A** — toggle the pi-chat panel
- **Mod+S** — toggle voice-to-text recording
- **Mod+L** / **Ctrl+Alt+L** — lock the screen (swaylock)
- **Mod+Shift+N** — restart the pi-chat panel (live-reload after rebuild)

See [docs/keybindings.md](docs/keybindings.md) for the full list of
keyboard shortcuts (distro additions plus the inherited niri defaults).

#### Voice-to-text

The full desktop module includes voice-to-text out of the box. Press
**Mod+S** to start recording and **Mod+S** again to stop. Speech is
transcribed locally and typed into the focused window.

### 2. Panel only (any layer-shell Wayland compositor)

Already using sway, Hyprland, KDE Plasma 6, or another
`wlr-layer-shell`-capable Wayland compositor? Import
`nixosModules.pi-chat` to get just the panel + AI agent + local LLM.
You keep your compositor.

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-unstable";
    distro.url = "github:generational-infrastructure/distro";
  };

  outputs = { nixpkgs, distro, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        distro.nixosModules.pi-chat
        ./configuration.nix
      ];
    };
  };
}
```

The panel runs as a user systemd service (`pi-chat.service`); it
starts at login alongside `graphical-session.target` and stays
running, hidden by default. Summon it with the bundled
`pi-chat-toggle` CLI:

```
pi-chat-toggle           # toggle visibility
pi-chat-toggle show      # force show
pi-chat-toggle hide      # force hide
```

Wire `pi-chat-toggle` to whatever compositor keybind you like. Under
the hood it calls
`quickshell ipc -c pi-chat call pi-chat toggle`, so you can also use
that directly if you prefer.

Examples:

**sway** (`~/.config/sway/config`)
```
bindsym $mod+a exec pi-chat-toggle
```

**Hyprland** (`~/.config/hypr/hyprland.conf`)
```
bind = SUPER, A, exec, pi-chat-toggle
```

**KDE Plasma 6**: System Settings → Shortcuts → Custom Shortcuts → add
a command shortcut bound to `pi-chat-toggle`.

If you also want voice-to-text, bind `voxtype record toggle` similarly.

## Hacking

### OpenRouter as an additional backend

The chat agent (`pi-chat`) defaults to the local LLM served by
llama-swap. You can add [OpenRouter](https://openrouter.ai) as an
additional backend — pi's built-in `openrouter` provider exposes
~200 curated models, switchable mid-session from the chat panel.

1. Create a key file on the target host (root-owned, mode `0400`):

   ```bash
   install -m 0400 -o root -g root /dev/stdin /etc/secrets/openrouter-api-key <<< "sk-or-v1-..."
   ```

2. Enable the provider in your NixOS config:

   ```nix
   services.pi-chat.openrouter = {
     enable = true;
     apiKeyFile = "/etc/secrets/openrouter-api-key";
   };
   ```

   The key is loaded as a systemd credential and resolved by pi at
   request time via `!cat $CREDENTIALS_DIRECTORY/openrouter-api-key` —
   it never lands in the nix store.

3. (Optional) Curate or override built-in model metadata via
   `piModels`:

   ```nix
   services.pi-chat.piModels.providers.openrouter.modelOverrides = {
     "anthropic/claude-sonnet-4.5".contextWindow = 200000;
   };
   ```

4. (Optional) Make an OpenRouter model the default at session start:

   ```nix
   services.pi-chat.defaultModel = "anthropic/claude-sonnet-4.5";
   ```

llama-swap stays enabled alongside; pick the provider per session
from the chat panel's model selector.

### Long-term memory (cross-session recall)

A local memory store extracts durable facts from each chat turn and
surfaces relevant ones at the start of any later prompt, across all
your chats. **On by default for each new chat**; the icon in the
panel header toggles capture and recall off for that chat, and the
eraser next to it wipes the entire store after an inline
confirmation.

Anything you type can be picked up by the extractor — flip the
toggle off before pasting secrets.

Inspect or prune from the terminal:

```bash
sediment stats
sediment list --scope all
sediment recall "favourite colour"
sediment forget <id>
```

### Running the test-machine VM test

`checks.x86_64-linux.test-machine` is dual-mode. With
`OPENROUTER_API_KEY` unset it exercises the local llama-swap backend.
With the env var set it switches the in-VM pi-chat to the openrouter
provider and runs a real round-trip against `api.openrouter.ai`.

Repo-local secrets live in `.env` (gitignored). [direnv] loads it on
directory entry via `.envrc`:

```bash
cp .env.example .env
$EDITOR .env          # fill in OPENROUTER_API_KEY
direnv allow
```

Then:

```bash
# Local-backend mode (default; works under `nix flake check` too):
nix build .#checks.x86_64-linux.test-machine

# OpenRouter mode (requires --impure so eval sees the env var; the
# derivation is marked __impure so the VM gets real internet):
nix build --impure .#checks.x86_64-linux.test-machine

# Interactive VM for poking around:
nix run --impure .#checks.x86_64-linux.test-machine.driverInteractive
```

In OpenRouter mode the key value is baked into the local `/nix/store`
— do not push the resulting store paths to a shared cache.

[direnv]: https://direnv.net

## License

See [LICENSE](LICENSE).
