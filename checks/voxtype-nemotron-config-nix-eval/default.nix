# Cheap nix-eval contract for the voxtype nemotron wiring
# (modules/nixos/voxtype.nix).
#
# The nemotron engine is NVIDIA's multilingual streaming ASR export, driven
# through parakeet-rs's `Nemotron` type. It reuses the `parakeet` ONNX feature
# (no dedicated cargo feature), so it needs a `parakeet*` package variant, and
# it carries its own `[nemotron]` config section. What a plain system build
# does NOT catch but the feature depends on:
#
#   - `spaces.voxtype.engine = "nemotron"` must serialize `engine = "nemotron"`
#     and emit a `[nemotron]` table. A typo in the enum or a missing engine
#     branch would fall back to whisper silently.
#   - `[nemotron] model` must carry the configured value verbatim (a store
#     path, or a passed-through registry name / absolute path). We assert on a
#     path override here to keep this check cheap: the default resolves to a
#     Nix-fetched ~2.6 GB model directory, whose realisation is deliberately
#     out of this ~1s check.
#   - `target_lang` and `streaming` reach the TOML under the snake_case keys
#     voxtype's serde expects, with the documented defaults.
#
# Builds only the generated config.toml derivation (independent of the voxtype
# package build and of the model download), then parses it with tomllib.
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

  mkSystem =
    extraModules:
    inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit inputs;
        flake = inputs.self;
      };
      modules = baseModules ++ [ inputs.self.nixosModules.spaces ] ++ extraModules;
    };

  # Defaults: engine = nemotron on a parakeet variant, model overridden to a
  # bare path so no model derivation is pulled into the check.
  defaultSystem = mkSystem [
    {
      networking.hostName = "voxtype-nemotron-default";
      spaces.voxtype.engine = "nemotron";
      spaces.voxtype.variant = "parakeet";
      spaces.voxtype.nemotronModel = "/models/nemotron-test";
    }
  ];

  # Overrides: streaming + a specific locale must flow through to the TOML.
  streamSystem = mkSystem [
    {
      networking.hostName = "voxtype-nemotron-stream";
      spaces.voxtype.engine = "nemotron";
      spaces.voxtype.variant = "parakeet";
      spaces.voxtype.nemotronModel = "/models/nemotron-test";
      spaces.voxtype.nemotronTargetLang = "es-ES";
      spaces.voxtype.streaming = true;
    }
  ];

  defaultConfigToml = defaultSystem.config.environment.etc."xdg/voxtype/config.toml".source;
  streamConfigToml = streamSystem.config.environment.etc."xdg/voxtype/config.toml".source;
in
pkgs.runCommand "voxtype-nemotron-config-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    inherit defaultConfigToml streamConfigToml;
  }
  ''
    set -euo pipefail
    python3 - "$defaultConfigToml" "$streamConfigToml" <<'PY'
    import sys, tomllib

    def load(path):
        with open(path, "rb") as fh:
            return tomllib.load(fh)

    def fail(msg):
        sys.stderr.write(f"FAIL: {msg}\n")
        sys.exit(1)

    default_cfg = load(sys.argv[1])
    stream_cfg = load(sys.argv[2])

    if default_cfg.get("engine") != "nemotron":
        fail(f'engine must be "nemotron", got {default_cfg.get("engine")!r}')

    nem = default_cfg.get("nemotron")
    if nem is None:
        fail("generated config has no [nemotron] table")
    if nem.get("model") != "/models/nemotron-test":
        fail(f'[nemotron] model must carry the configured value, got {nem.get("model")!r}')
    if nem.get("target_lang") != "auto":
        fail(f'[nemotron] target_lang default must be "auto", got {nem.get("target_lang")!r}')
    if nem.get("streaming") is not False:
        fail(f'[nemotron] streaming default must be false, got {nem.get("streaming")!r}')

    stream_nem = stream_cfg.get("nemotron", {})
    if stream_nem.get("streaming") is not True:
        fail(f'streaming = true must serialize [nemotron] streaming = true, got {stream_nem.get("streaming")!r}')
    if stream_nem.get("target_lang") != "es-ES":
        fail(f'nemotronTargetLang must flow through, got {stream_nem.get("target_lang")!r}')

    sys.stderr.write("PASS: voxtype config wires the nemotron engine, model, target_lang and streaming\n")
    PY
    touch "$out"
  ''
