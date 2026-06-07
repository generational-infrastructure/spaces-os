# Behavioural contract for the voice-record-toggle spaces wrapper
# (modules/nixos/spaces-commands.nix).
#
# Recording state is now surfaced by the on-screen voxtype indicator (a
# red dot — see voxtype-indicator.nix), so the wrapper no longer posts a
# "voice recording started/stopped" transition toast. Its whole job is to
# flip the daemon: `voxtype record toggle`. On success it must stay quiet;
# a failure still posts the mkCommand "failed to …" toast (covered by the
# generic wrapper behaviour, not re-asserted here).
#
# We exercise the real shipped wrapper (pulled from the evaluated system)
# with stubbed `voxtype`/`notify-send`. ~3-5s.
{ pkgs, inputs, ... }:
let
  system = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = {
      inherit inputs;
      flake = inputs.self;
    };
    modules = [
      inputs.self.nixosModules.spaces-commands
      {
        nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        boot.loader.grub.enable = false;
        system.stateVersion = "26.05";
      }
    ];
  };
  wrapper = system.config.services.spaces.commands.voice-record-toggle;

  # `voxtype record toggle` must be invoked; record the argv so the test
  # can assert the wrapper actually toggles. `voxtype status` is no longer
  # called by the wrapper, but stub it harmlessly in case.
  stubVoxtype = pkgs.writeShellScriptBin "voxtype" ''
    printf '%s\n' "$*" >> "$VOX_WITNESS"
  '';
  stubNotify = pkgs.writeShellScriptBin "notify-send" ''
    printf '%s\n' "$*" >> "$NOTIFY_WITNESS"
  '';
in
pkgs.runCommand "spaces-voice-record-toggle-test" { } ''
  set -euo pipefail
  export VOX_WITNESS="$PWD/voxtype.log"
  export NOTIFY_WITNESS="$PWD/notify.log"
  : > "$VOX_WITNESS"
  : > "$NOTIFY_WITNESS"
  export PATH=${stubVoxtype}/bin:${stubNotify}/bin:$PATH

  ${wrapper}/bin/${wrapper.name}

  # The wrapper must flip the daemon.
  grep -qx 'record toggle' "$VOX_WITNESS" \
    || { echo "FAIL: wrapper must invoke 'voxtype record toggle'" >&2; cat "$VOX_WITNESS" >&2; exit 1; }

  # ...and stay silent: no recording-transition toast (the indicator owns
  # that feedback now).
  if grep -qi 'voice recording' "$NOTIFY_WITNESS"; then
    echo "FAIL: wrapper must not post a voice-recording notification" >&2
    cat "$NOTIFY_WITNESS" >&2
    exit 1
  fi

  touch "$out"
''
