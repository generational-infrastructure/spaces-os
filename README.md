# distro

AI agent desktop integration for NixOS. Chat with a local AI agent
directly from your desktop bar.

The stack: [niri](https://github.com/YaLTeR/niri) (Wayland compositor) +
[noctalia](https://github.com/noctalia-dev/noctalia-shell) (desktop shell) +
[pi](https://github.com/mariozechner/pi-mono) (coding agent) +
[llama-swap](https://github.com/mostlygeek/llama-swap) (local LLM server) +
voice-to-text.

## Three ways to use it

| Integration | What you get | You provide |
|---|---|---|
| **Full desktop** | Niri compositor, noctalia bar with chat widget, AI agent, local LLM | A NixOS machine |
| **Noctalia bar** | Noctalia bar with chat widget + agent backend | Your own compositor (GNOME, Sway, Hyprland, …) |
| **Noctalia plugin** | Chat widget + agent backend (enabled by default) | An existing noctalia install |

## Binary Cache

Configure the [numtide binary cache](https://cache.numtide.com/index.html) to
avoid building dependencies from source.

## Setup

All three integration levels consume this flake as a NixOS module.

### 1. Full desktop

Import `nixosModules.distro` for the complete experience: niri compositor,
noctalia shell bar with chat widget, pi-chat agent, and local LLM server.
The module enables the AI agent, chat widget, and greetd auto-login into niri
by default.

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
- **Super+A** — toggle the chat panel
- **Super+S** — toggle voice-to-text recording
- Noctalia bar with system tray, workspaces, and chat widget

#### Voice-to-text

The full desktop module includes voice-to-text out of the box. Press
**Super+S** to start recording and **Super+S** again to stop. Speech is
transcribed locally and typed into the focused window.

### 2. Noctalia bar (any compositor)

Already using GNOME, Sway, Hyprland, or another Wayland compositor? Import
`nixosModules.noctalia-bar` to get the noctalia bar with the AI chat widget.
You keep your compositor.  The module enables the AI agent and chat widget by
default.

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-unstable";
    distro.url = "github:numtide/distro";
  };

  outputs = { nixpkgs, distro, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        distro.nixosModules.noctalia-bar
        ./configuration.nix
      ];
    };
  };
}
```

After enabling the NixOS module, open noctalia's **Settings → Plugins** and
enable the **AI Chat** plugin.

The chat panel and voice-to-text rely on compositor-level keybinds.
`nixosModules.distro` wires `Super+A` and `Super+S` into niri for you;
with any other compositor you set them up yourself. Bind whatever keys
you like to these commands:

- chat panel: `noctalia-shell ipc call plugin:pi-chat toggle`
- voice-to-text: `voxtype record toggle` (only if you imported the
  `voxtype` module — see below)

#### Voice-to-text

The noctalia-bar module does **not** include voice-to-text. To add it, import
the module alongside:

```nix
modules = [
  distro.nixosModules.noctalia-bar
  distro.nixosModules.voxtype  # voice-to-text
  ./configuration.nix
];
```

Then add `noctalia-shell` to your compositor's autostart:

**Sway**
```
# ~/.config/sway/config
exec noctalia-shell
```

**Hyprland**
```
# ~/.config/hypr/hyprland.conf
exec-once = noctalia-shell
```

### 3. Plugin only (existing noctalia)

Already running noctalia? Import `nixosModules.noctalia-plugin` to add just the
chat widget and agent backend.  The module enables the AI agent and chat widget
by default.

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-unstable";
    distro.url = "github:numtide/distro";
  };

  outputs = { nixpkgs, distro, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        distro.nixosModules.noctalia-plugin
        ./configuration.nix
      ];
    };
  };
}
```
As with integration 2, `Super+A` / `Super+S` are only bound automatically
under `nixosModules.distro`. On any other compositor, bind your own keys
to `noctalia-shell ipc call plugin:pi-chat toggle` (and
`voxtype record toggle` if you also imported `nixosModules.voxtype`).

Apply `overlays.noctalia` so distro can auto-enable its plugins:

```nix
{ nixpkgs.overlays = [ inputs.distro.overlays.noctalia ]; }
```

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
