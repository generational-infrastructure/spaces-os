# Behavioural contract for the voice-record-toggle spaces wrapper
# (modules/nixos/spaces-commands.nix).
#
# `voxtype record toggle` flips recording on/off but says nothing about
# which way it went. The wrapper must report the actual transition:
# read the daemon state first (`voxtype status`), then toggle, then post
# "voice recording started" or "voice recording stopped" — mirroring
# voxtype's own rule (state == "recording" => the toggle stops it).
#
# We exercise the real shipped wrapper (pulled from the evaluated
# system) with stubbed `voxtype`/`notify-send`, so the start/stop
# wording can't drift from what voxtype actually does. ~3-5s.
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

  # `voxtype status` reports the current state; `voxtype record toggle`
  # just has to succeed. State is taken from $VOX_STATE so the test can
  # drive both transitions.
  stubVoxtype = pkgs.writeShellScriptBin "voxtype" ''
    case "$1" in
      status) printf '%s\n' "''${VOX_STATE:-idle}" ;;
      *) : ;;
    esac
  '';
  stubNotify = pkgs.writeShellScriptBin "notify-send" ''
    printf '%s\n' "$*" >> "$NOTIFY_WITNESS"
  '';
in
pkgs.runCommand "spaces-voice-record-toggle-test" { } ''
  set -euo pipefail
  export NOTIFY_WITNESS="$PWD/notify.log"
  export PATH=${stubVoxtype}/bin:${stubNotify}/bin:$PATH

  # Idle daemon: a toggle starts recording.
  : > "$NOTIFY_WITNESS"
  VOX_STATE=idle ${wrapper}/bin/${wrapper.name}
  grep -q 'voice recording started' "$NOTIFY_WITNESS" \
    || { echo "FAIL: toggle from idle must report 'started'" >&2; cat "$NOTIFY_WITNESS" >&2; exit 1; }
  grep -q -- '--expire-time=2000' "$NOTIFY_WITNESS" \
    || { echo "FAIL: recording toast must expire after 2s (--expire-time=2000)" >&2; cat "$NOTIFY_WITNESS" >&2; exit 1; }
  if grep -q 'stopped' "$NOTIFY_WITNESS"; then
    echo "FAIL: toggle from idle reported 'stopped'" >&2; cat "$NOTIFY_WITNESS" >&2; exit 1
  fi

  # Active recording: a toggle stops it (voxtype's rule: state == recording).
  : > "$NOTIFY_WITNESS"
  VOX_STATE=recording ${wrapper}/bin/${wrapper.name}
  grep -q 'voice recording stopped' "$NOTIFY_WITNESS" \
    || { echo "FAIL: toggle while recording must report 'stopped'" >&2; cat "$NOTIFY_WITNESS" >&2; exit 1; }
  grep -q -- '--expire-time=2000' "$NOTIFY_WITNESS" \
    || { echo "FAIL: recording toast must expire after 2s (--expire-time=2000)" >&2; cat "$NOTIFY_WITNESS" >&2; exit 1; }
  if grep -q 'started' "$NOTIFY_WITNESS"; then
    echo "FAIL: toggle while recording reported 'started'" >&2; cat "$NOTIFY_WITNESS" >&2; exit 1
  fi

  touch "$out"
''
