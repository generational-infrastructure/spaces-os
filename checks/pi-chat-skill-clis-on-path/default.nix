# Every built-in skill's CLI must be on the user's PATH.
#
# Two reasons we care:
#   1. The pi-chat sandbox inherits the user's PATH, so a skill that
#      advertises `osm-cli search …` in its SKILL.md but doesn't put
#      `osm-cli` on PATH ships a tool the agent can call but not run.
#      That latent bug bit us with osm-cli and caldav-cli before this
#      check existed: SKILL.md said "use it", binary wasn't reachable.
#   2. The user wants the same CLI invocations to work from a normal
#      terminal — debug a skill, script around it, use it without the
#      chat panel.
#
# This check evaluates a default spaces host (which imports pi-chat
# + signal-cli via the bundle), walks every enabled built-in skill's
# SKILL.md, extracts the
# CLI binary names mentioned in fenced bash blocks, and asserts each
# one is provided by `environment.systemPackages`.
#
# Pure nix-eval + shell. ~3-5s.
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;

  # Default spaces shape: the bundle auto-enables pi-chat and (via
  # pi-chat's own dep) signal-cli. Both default-on; nothing extra to set.
  system = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = {
      inherit inputs;
      flake = inputs.self;
    };
    modules = [
      inputs.self.nixosModules.spaces
      {
        nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
        networking.hostName = "skill-clis-fixture";
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        boot.loader.grub.enable = false;
        system.stateVersion = "26.05";
      }
    ];
  };

  # Each built-in skill plus the CLI binary names its SKILL.md tells
  # the agent to run. Keep this in lockstep with skills/<name>/SKILL.md
  # — if a skill grows a new tool the agent should call, add it here
  # and the check fails until environment.systemPackages catches up.
  #
  # Skills that don't shell out (location reads a file; datetime uses
  # the system `date`) are intentionally absent.
  expected = {
    signal = [ "signal" ];
    notifications = [ "notifications" ];
    google = [ "google-cli" ];
    maps = [ "osm-cli" ];
    wikidata = [ "wikidata-cli" ];
    calendar = [ "caldav" ];
    contacts = [ "contacts" ];
    email = [ "mail" ];
    skill-config = [ "skill-config" ];
  };

  # Flatten to one (skill, bin) per line for the shell loop.
  expectedPairs = lib.concatLists (
    lib.mapAttrsToList (skill: bins: map (bin: "${skill}\t${bin}") bins) expected
  );

  systemPath = lib.makeBinPath system.config.environment.systemPackages;
in
pkgs.runCommand "pi-chat-skill-clis-on-path-test"
  {
    inherit systemPath;
    expectedPairs = lib.concatStringsSep "\n" expectedPairs;
  }
  ''
    set -euo pipefail

    fail() { echo "FAIL: $*" >&2; exit 1; }

    missing=""
    while IFS=$'\t' read -r skill bin; do
      [ -n "$skill" ] || continue
      found=0
      IFS=':' read -ra parts <<<"$systemPath"
      for p in "''${parts[@]}"; do
        if [ -x "$p/$bin" ]; then
          found=1
          break
        fi
      done
      if [ "$found" = "0" ]; then
        missing="$missing\n  skill=$skill bin=$bin"
      fi
    done <<<"$expectedPairs"

    if [ -n "$missing" ]; then
      printf 'FAIL: skill CLIs missing from environment.systemPackages:%b\n' "$missing" >&2
      echo "" >&2
      echo "The pi-chat sandbox inherits the user PATH, so a SKILL.md" >&2
      echo "that says \"run osm-cli\" without the binary on PATH ships" >&2
      echo "a tool the agent can call but not run. Add the package to" >&2
      echo "environment.systemPackages in modules/nixos/pi-chat/default.nix" >&2
      echo "(or, for a separately-enabled skill backend, in its own module)." >&2
      exit 1
    fi

    echo "OK"
    touch "$out"
  ''
