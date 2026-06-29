# NixOS option → daemon env wiring for sandboxAllowedPaths.
#
# NixOS modules that ship a skill publish their host paths via
# services.pi-chat.sandboxAllowedPaths; pi-chat forwards them into
# services.pi-sessiond-local.allowedPaths AFTER its own five baseline
# grants (skill-config socket, open-url socket, skills-defs, the
# skill-config store, notifications). The daemon module serializes
# that list as JSON into the user unit env var
# SPACES_SESSIOND_ALLOWED_PATHS, which pi-sessiond folds into each
# per-session pi child's Landlock FS allowlist by access mode.
#
# This check evaluates a NixOS system with a fixture list and asserts:
#   - the env JSON carries an entry per fixture, after the baselines,
#     each with exactly { source, mode } — the bind-mount-era `target`
#     and `optional` fields are gone (Landlock grants the path in place,
#     no remapping, and pi-landlock-exec skips a missing path non-fatally);
#   - /etc/spaces/pi-chat.json no longer carries a sandboxAllowedPaths key
#     (the panel never sees grants anymore — only the daemon does);
#   - with no sandboxAllowedPaths set, the env JSON is exactly the five
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
      mode = "rw";
    }
    {
      source = "%h/.local/share/signal-cli/attachments";
      mode = "ro";
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

          # Test the sandboxAllowedPaths wiring contract in isolation. The
          # signal-cli module would otherwise inject entries of its
          # own (default-on with pi-chat) and the fixture counts
          # would lie.
          services.spaces-signal.enable = false;
        }
        extraConfig
      ];
    };

  fixtureSystem = mkSystem "sandbox-allowed-paths-fixture" {
    services.pi-chat.sandboxAllowedPaths = fixture;
  };

  # No sandboxAllowedPaths set anywhere — the daemon env must carry exactly
  # the five pi-chat baseline grants and nothing else.
  defaultSystem = mkSystem "sandbox-allowed-paths-default" { };

  allowedPathsEnv =
    system:
    system.config.systemd.user.services.pi-sessiond-local.environment.SPACES_SESSIOND_ALLOWED_PATHS;
in
pkgs.runCommand "pi-chat-sandbox-allowed-paths-nix-test"
  {
    nativeBuildInputs = [ pkgs.jq ];
    configFile = fixtureSystem.config.environment.etc."spaces/pi-chat.json".source;
    allowedPaths = allowedPathsEnv fixtureSystem;
    defaultAllowedPaths = allowedPathsEnv defaultSystem;
  }
  ''
    set -euo pipefail

    # 1. Env var is valid JSON.
    if ! jq -e . >/dev/null <<<"$allowedPaths"; then
      echo "FAIL: SPACES_SESSIOND_ALLOWED_PATHS is not valid JSON: $allowedPaths"
      exit 1
    fi

    # 2. Five pi-chat baselines + the three forwarded fixtures.
    count=$(jq -r 'length' <<<"$allowedPaths")
    if [ "$count" != "8" ]; then
      echo "FAIL: expected 8 grants (5 baseline + 3 fixture), got $count"
      jq . <<<"$allowedPaths"
      exit 1
    fi

    # 3. Every entry is exactly { source, mode } — the daemon emits only
    # what Landlock can act on; no leftover bind-mount target/optional.
    jq -e 'all(.[]; (keys | sort) == ["mode", "source"])' >/dev/null <<<"$allowedPaths" || {
      echo "FAIL: a grant entry carries keys other than source/mode"
      jq . <<<"$allowedPaths"
      exit 1
    }

    # 4. The three fixtures are forwarded verbatim, in order, after the
    # five baselines (indices 5..7).
    jq -e '.[5:8] == [
      { source: "%t/signal-cli/socket",                   mode: "rw" },
      { source: "%h/.local/state/spaces/signal",          mode: "rw" },
      { source: "%h/.local/share/signal-cli/attachments", mode: "ro" }
    ]' >/dev/null <<<"$allowedPaths" || {
      echo "FAIL: forwarded fixtures mismatch"
      jq '.[5:8]' <<<"$allowedPaths"
      exit 1
    }

    # 5. The panel config carries NO sandboxAllowedPaths key anymore — grants
    # go to the daemon, the panel never assembles a sandbox itself.
    jq -e . "$configFile" >/dev/null || {
      echo "FAIL: $configFile is not valid JSON"
      exit 1
    }
    if jq -e 'has("sandboxAllowedPaths")' "$configFile" >/dev/null; then
      echo "FAIL: pi-chat.json still carries a sandboxAllowedPaths key"
      jq '.sandboxAllowedPaths' "$configFile"
      exit 1
    fi

    # 6. Default — with no sandboxAllowedPaths set, the daemon env is exactly
    # the five pi-chat baseline grants, in order, sockets first.
    jq -e '. == [
      { source: "%t/spaces-skill-config.sock",             mode: "rw" },
      { source: "%t/spaces-pi-open-url.sock",              mode: "rw" },
      { source: "%h/.local/state/spaces/pi/skills-defs",   mode: "ro" },
      { source: "%h/.local/state/spaces/pi/skill-config",  mode: "rw" },
      { source: "%h/.local/state/spaces/pi/notifications", mode: "ro" }
    ]' >/dev/null <<<"$defaultAllowedPaths" || {
      echo "FAIL: default SPACES_SESSIOND_ALLOWED_PATHS is not exactly the 5 baseline grants"
      jq . <<<"$defaultAllowedPaths"
      exit 1
    }

    echo "OK"
    touch "$out"
  ''
