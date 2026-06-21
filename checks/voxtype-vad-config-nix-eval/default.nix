# Cheap nix-eval contract for the voxtype VAD wiring
# (modules/nixos/voxtype.nix).
#
# The voice-indicator's "no speech" warning depends on voxtype actually
# rejecting silent takes before transcription — which only happens when the
# generated config carries a [vad] block. What a plain system build does NOT
# catch but the feature depends on:
#
#   - VAD is on BY DEFAULT (spaces.voxtype.vad.enable defaults true), so the
#     bundled config ships [vad] enabled = true;
#   - the backend is pinned to "energy" — NOT "auto". This is the offline
#     guarantee: "auto" would pick Whisper/Silero VAD for the whisper engine
#     and download ggml-silero-vad.bin on first use, breaking the closure.
#     A wrong backend builds fine yet silently breaks offline hosts;
#   - the threshold / min-speech tunables reach the TOML as the documented
#     defaults, under the snake_case keys voxtype's serde expects.
#
# Builds only the generated config.toml derivation (independent of the
# voxtype package build), then parses it with tomllib. ~1s, no VM.
{ pkgs, inputs, ... }:
let
  baseModules = [
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

  spacesSystem = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = {
      inherit inputs;
      flake = inputs.self;
    };
    modules = baseModules ++ [
      inputs.self.nixosModules.spaces
      { networking.hostName = "voxtype-vad"; }
    ];
  };

  # The system-wide voxtype config the daemon runs with. A standalone
  # pkgs.formats.toml derivation — realising it does not build voxtype.
  configToml = spacesSystem.config.environment.etc."xdg/voxtype/config.toml".source;
in
pkgs.runCommand "voxtype-vad-config-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    inherit configToml;
  }
  ''
    set -euo pipefail
    python3 - "$configToml" <<'PY'
    import sys, tomllib

    with open(sys.argv[1], "rb") as fh:
        cfg = tomllib.load(fh)

    def fail(msg):
        sys.stderr.write(f"FAIL: {msg}\n")
        sys.exit(1)

    vad = cfg.get("vad")
    if vad is None:
        fail("generated config has no [vad] block — VAD is off by default")
    if vad.get("enabled") is not True:
        fail(f"[vad] enabled must be true, got {vad.get('enabled')!r}")
    if vad.get("backend") != "energy":
        fail(
            f"[vad] backend must be \"energy\" (pure-Rust, offline); "
            f'"auto" downloads a Silero model. got {vad.get("backend")!r}'
        )
    if vad.get("threshold") != 0.4:
        fail(f"[vad] threshold default must be 0.4, got {vad.get('threshold')!r}")
    if vad.get("min_speech_duration_ms") != 100:
        fail(
            "[vad] min_speech_duration_ms default must be 100, "
            f"got {vad.get('min_speech_duration_ms')!r}"
        )

    sys.stderr.write("PASS: voxtype config ships [vad] energy backend by default\n")
    PY
    touch "$out"
  ''
