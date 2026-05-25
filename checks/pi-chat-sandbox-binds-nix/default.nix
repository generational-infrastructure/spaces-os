# NixOS option → /etc/distro/pi-chat.json wiring for sandboxBinds.
#
# Evaluates a NixOS system with services.pi-chat.sandboxBinds set to a
# fixture list, materializes the etc-file the panel reads at startup,
# and asserts the JSON contains an entry per fixture with all four
# fields (source, target, mode, optional) preserved. This is the
# contract every NixOS module that adds a skill via sandboxBinds
# relies on: the panel must see exactly what they declared.
#
# Pure nix-eval + jq. No VM, no quickshell. ~3s.
{ pkgs, inputs, ... }:
let
  fixture = [
    {
      source = "%t/signal-cli/socket";
      mode = "rw";
    }
    {
      source = "%h/.local/state/distro/signal";
      target = "/state/signal";
      mode = "rw";
    }
    {
      source = "%h/.local/share/signal-cli/attachments";
      mode = "ro";
      optional = true;
    }
  ];

  fixtureSystem = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = {
      inherit inputs;
      flake = inputs.self;
    };
    modules = [
      inputs.self.nixosModules.noctalia-bar
      {
        nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
        networking.hostName = "sandbox-binds-fixture";
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        boot.loader.grub.enable = false;
        system.stateVersion = "26.05";

        # Test the sandboxBinds wiring contract in isolation. The
        # signal-cli module would otherwise inject four entries of
        # its own (default-on with pi-chat) and the fixture counts
        # would lie.
        services.distro-signal.enable = false;
        services.pi-chat.sandboxBinds = fixture;
      }
    ];
  };

  configFile = fixtureSystem.config.environment.etc."distro/pi-chat.json".source;
in
pkgs.runCommand "pi-chat-sandbox-binds-nix-test"
  {
    nativeBuildInputs = [ pkgs.jq ];
    inherit configFile;
  }
  ''
    set -euo pipefail

    # 1. JSON exists and parses.
    if ! jq -e . "$configFile" >/dev/null; then
      echo "FAIL: $configFile is not valid JSON"
      exit 1
    fi

    # 2. sandboxBinds key is present and has exactly 3 entries.
    count=$(jq -r '.sandboxBinds | length' "$configFile")
    if [ "$count" != "3" ]; then
      echo "FAIL: expected 3 sandboxBinds, got $count"
      jq . "$configFile"
      exit 1
    fi

    # 3. Entry 0: %t source, rw, target defaults to null.
    jq -e '.sandboxBinds[0]
      | .source == "%t/signal-cli/socket"
      and .mode == "rw"
      and .target == null
      and .optional == false' "$configFile" >/dev/null || {
      echo "FAIL: entry 0 mismatch"
      jq '.sandboxBinds[0]' "$configFile"
      exit 1
    }

    # 4. Entry 1: explicit target, rw.
    jq -e '.sandboxBinds[1]
      | .source == "%h/.local/state/distro/signal"
      and .target == "/state/signal"
      and .mode == "rw"
      and .optional == false' "$configFile" >/dev/null || {
      echo "FAIL: entry 1 mismatch"
      jq '.sandboxBinds[1]' "$configFile"
      exit 1
    }

    # 5. Entry 2: ro + optional.
    jq -e '.sandboxBinds[2]
      | .source == "%h/.local/share/signal-cli/attachments"
      and .mode == "ro"
      and .optional == true
      and .target == null' "$configFile" >/dev/null || {
      echo "FAIL: entry 2 mismatch"
      jq '.sandboxBinds[2]' "$configFile"
      exit 1
    }

    # 6. Default — an unrelated system without sandboxBinds set should
    # serialize an empty list (not null, not missing) so the QML side
    # can iterate it without a null check.
    default_count=$(jq -r '.sandboxBinds | length' "${
      (inputs.nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit inputs;
          flake = inputs.self;
        };
        modules = [
          inputs.self.nixosModules.noctalia-bar
          {
            nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
            networking.hostName = "sandbox-binds-default";
            fileSystems."/" = {
              device = "none";
              fsType = "tmpfs";
            };
            boot.loader.grub.enable = false;
            system.stateVersion = "26.05";

            # Same isolation as above: with distro-signal default-on
            # the "default" system would have four entries, not zero.
            services.distro-signal.enable = false;
          }
        ];
      }).config.environment.etc."distro/pi-chat.json".source
    }")
    if [ "$default_count" != "0" ]; then
      echo "FAIL: default sandboxBinds should be empty, got $default_count entries"
      exit 1
    fi

    echo "OK"
    touch "$out"
  ''
