# Cheap nix-eval contract for the voxtype whisper-language wiring
# (modules/nixos/voxtype.nix).
#
# spaces.voxtype.whisperLanguage accepts EITHER a bare string (single
# language, the historic behaviour) OR a list of strings (voxtype's
# multilingual dictation). The two shapes must serialize differently in the
# generated config.toml, and a plain system build does NOT catch this:
#
#   - the default is the bare string "auto", which pkgs.formats.toml must emit
#     as a TOML string (language = "auto"). This keeps today's config
#     byte-identical; regressing the default to ["auto"] would silently change
#     every existing host's emitted TOML;
#   - a list value must land as a TOML array (language = ["en","ru"]), NOT a
#     stringified list. voxtype reads a string as one language and an array as
#     the multilingual set, so the array shape is load-bearing.
#
# Builds only the generated config.toml derivation (independent of the voxtype
# package build) for both the default and an overridden system, then parses
# each with tomllib. ~1s, no VM.
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

  # Default: whisperLanguage keeps its historic bare-string default "auto".
  defaultSystem = mkSystem [ { networking.hostName = "voxtype-lang-default"; } ];

  # Override: a list value must flow through to a TOML array.
  listSystem = mkSystem [
    {
      networking.hostName = "voxtype-lang-list";
      spaces.voxtype.whisperLanguage = [
        "en"
        "ru"
      ];
    }
  ];

  defaultConfigToml = defaultSystem.config.environment.etc."xdg/voxtype/config.toml".source;
  listConfigToml = listSystem.config.environment.etc."xdg/voxtype/config.toml".source;
in
pkgs.runCommand "voxtype-language-config-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    inherit defaultConfigToml listConfigToml;
  }
  ''
    set -euo pipefail
    python3 - "$defaultConfigToml" "$listConfigToml" <<'PY'
    import sys, tomllib

    def load(path):
        with open(path, "rb") as fh:
            return tomllib.load(fh)

    def fail(msg):
        sys.stderr.write(f"FAIL: {msg}\n")
        sys.exit(1)

    default_cfg = load(sys.argv[1])
    list_cfg = load(sys.argv[2])

    default_lang = default_cfg.get("whisper", {}).get("language")
    if default_lang != "auto":
        fail(
            'default whisper.language must be the bare string "auto" '
            f"(byte-identical to today's config), got {default_lang!r}"
        )

    list_lang = list_cfg.get("whisper", {}).get("language")
    if list_lang != ["en", "ru"]:
        fail(
            'whisperLanguage = [ "en" "ru" ] must serialize as a TOML array '
            f'["en","ru"], got {list_lang!r}'
        )

    sys.stderr.write(
        "PASS: whisper.language is a string by default and a TOML array for a list value\n"
    )
    PY
    touch "$out"
  ''
