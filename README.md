# distro

AI agent desktop integration for NixOS. Chat with a local AI agent
directly from your desktop bar.

The stack: [niri](https://github.com/YaLTeR/niri) (Wayland compositor) +
[noctalia](https://github.com/noctalia-dev/noctalia-shell) (desktop shell) +
[opencrow](https://github.com/pinpox/opencrow) (AI agent backend) +
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
noctalia shell bar with chat widget, opencrow AI agent, and local LLM server.
The module enables the AI agent, chat widget, and greetd auto-login into niri
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

- chat panel: `noctalia-shell ipc call plugin:opencrow-chat toggle`
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
After enabling the NixOS module, open noctalia's **Settings → Plugins** and
enable the **AI Chat** plugin. Alternatively, add
`{ id = "plugin:opencrow-chat"; }` to your `settings.json` widget layout.

As with integration 2, `Super+A` / `Super+S` are only bound automatically
under `nixosModules.distro`. On any other compositor, bind your own keys
to `noctalia-shell ipc call plugin:opencrow-chat toggle` (and
`voxtype record toggle` if you also imported `nixosModules.voxtype`).

## License

See [LICENSE](LICENSE).
