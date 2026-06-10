# NixOS option → daemon env wiring for sandboxBinds.
#
# NixOS modules that ship a skill publish their host paths via
# services.pi-chat.sandboxBinds; pi-chat forwards them into
# services.pi-sessiond-local.bashBinds AFTER its own five baseline
# binds (skill-config socket, open-url socket, skills-defs, the
# skill-config store, notifications). The daemon module serializes
# that list as JSON into the user unit env var
# SPACES_SESSIOND_BASH_BINDS, which pi-sessiond turns into systemd-run
# BindPaths/BindReadOnlyPaths on every per-bash sandbox.
#
# This check evaluates a NixOS system with a fixture list and asserts:
#   - the env JSON carries an entry per fixture, after the baselines,
#     with mode/optional preserved and `target` ABSENT (not null) when
#     it was left at its default;
#   - /etc/spaces/pi-chat.json no longer carries a sandboxBinds key
#     (the panel never sees binds anymore — only the daemon does);
#   - with no sandboxBinds set, the env JSON is exactly the five
#     pi-chat baseline entries.
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
      source = "%h/.local/state/spaces/signal";
      target = "/state/signal";
      mode = "rw";
    }
    {
      source = "%h/.local/share/signal-cli/attachments";
      mode = "ro";
      optional = true;
    }
  ];

  mkSystem =
    hostName: extraConfig:
    inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit inputs;
        flake = inputs.self;
      };
      modules = [
        inputs.self.nixosModules.spaces
        {
          nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
          networking.hostName = hostName;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          boot.loader.grub.enable = false;
          system.stateVersion = "26.05";

          # Test the sandboxBinds wiring contract in isolation. The
          # signal-cli module would otherwise inject entries of its
          # own (default-on with pi-chat) and the fixture counts
          # would lie.
          services.spaces-signal.enable = false;
        }
        extraConfig
      ];
    };

  fixtureSystem = mkSystem "sandbox-binds-fixture" {
    services.pi-chat.sandboxBinds = fixture;
  };

  # No sandboxBinds set anywhere — the daemon env must carry exactly
  # the five pi-chat baseline binds and nothing else.
  defaultSystem = mkSystem "sandbox-binds-default" { };

  bindsEnv =
    system:
    system.config.systemd.user.services.pi-sessiond-local.environment.SPACES_SESSIOND_BASH_BINDS;
in
pkgs.runCommand "pi-chat-sandbox-binds-nix-test"
  {
    nativeBuildInputs = [ pkgs.jq ];
    configFile = fixtureSystem.config.environment.etc."spaces/pi-chat.json".source;
    bashBinds = bindsEnv fixtureSystem;
    defaultBashBinds = bindsEnv defaultSystem;
  }
  ''
    set -euo pipefail

    # 1. Env var is valid JSON.
    if ! jq -e . >/dev/null <<<"$bashBinds"; then
      echo "FAIL: SPACES_SESSIOND_BASH_BINDS is not valid JSON: $bashBinds"
      exit 1
    fi

    # 2. Five pi-chat baselines + the three forwarded fixtures.
    count=$(jq -r 'length' <<<"$bashBinds")
    if [ "$count" != "8" ]; then
      echo "FAIL: expected 8 binds (5 baseline + 3 fixture), got $count"
      jq . <<<"$bashBinds"
      exit 1
    fi

    # 3. Fixture entry 0 (index 5): %t source, rw, target ABSENT —
    # the module omits defaulted targets instead of serializing null.
    jq -e '.[5]
      | .source == "%t/signal-cli/socket"
      and .mode == "rw"
      and (has("target") | not)
      and .optional == false' >/dev/null <<<"$bashBinds" || {
      echo "FAIL: fixture entry 0 mismatch"
      jq '.[5]' <<<"$bashBinds"
      exit 1
    }

    # 4. Fixture entry 1 (index 6): explicit target, rw.
    jq -e '.[6]
      | .source == "%h/.local/state/spaces/signal"
      and .target == "/state/signal"
      and .mode == "rw"
      and .optional == false' >/dev/null <<<"$bashBinds" || {
      echo "FAIL: fixture entry 1 mismatch"
      jq '.[6]' <<<"$bashBinds"
      exit 1
    }

    # 5. Fixture entry 2 (index 7): ro + optional, target absent.
    jq -e '.[7]
      | .source == "%h/.local/share/signal-cli/attachments"
      and .mode == "ro"
      and .optional == true
      and (has("target") | not)' >/dev/null <<<"$bashBinds" || {
      echo "FAIL: fixture entry 2 mismatch"
      jq '.[7]' <<<"$bashBinds"
      exit 1
    }

    # 6. The panel config carries NO sandboxBinds key anymore — binds
    # go to the daemon, the panel never assembles a sandbox itself.
    jq -e . "$configFile" >/dev/null || {
      echo "FAIL: $configFile is not valid JSON"
      exit 1
    }
    if jq -e 'has("sandboxBinds")' "$configFile" >/dev/null; then
      echo "FAIL: pi-chat.json still carries a sandboxBinds key"
      jq '.sandboxBinds' "$configFile"
      exit 1
    fi

    # 7. Default — with no sandboxBinds set, the daemon env is exactly
    # the five pi-chat baseline binds, in order, sockets first.
    jq -e '. == [
      { source: "%t/spaces-skill-config.sock",                mode: "rw", optional: true  },
      { source: "%t/spaces-pi-open-url.sock",                 mode: "rw", optional: true  },
      { source: "%h/.local/state/spaces/pi/skills-defs",      mode: "ro", optional: false },
      { source: "%h/.local/state/spaces/pi/skill-config",     mode: "rw", optional: false },
      { source: "%h/.local/state/spaces/pi/notifications",    mode: "ro", optional: false }
    ]' >/dev/null <<<"$defaultBashBinds" || {
      echo "FAIL: default SPACES_SESSIOND_BASH_BINDS is not exactly the 5 baseline binds"
      jq . <<<"$defaultBashBinds"
      exit 1
    }

    echo "OK"
    touch "$out"
  ''
