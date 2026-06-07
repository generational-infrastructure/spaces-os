# Voice-to-text via voxtype (push-to-talk / toggle mode)
#
# Installs voxtype, writes a system-wide default config, and creates a
# systemd user service that starts with the graphical session.
#
# Two engines are supported:
#   - whisper  (default): whisper.cpp, batch transcription. Uses the
#     `vulkan` package variant (AMD/Intel GPU, no CUDA) and a Nix-fetched
#     ggml model so the closure is fully offline.
#   - parakeet: NVIDIA FastConformer via ONNX. With `streaming = true`
#     voxtype emits live partial transcripts during recording and types
#     the final transcript on release. Requires a parakeet-feature build
#     (one of the `parakeet*` package variants) and a streaming-capable
#     model directory, which voxtype downloads on first use into
#     ~/.local/share/voxtype/models/.
#
# Keybinding: Mod+Space  (defined in niri.nix)
{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.spaces.voxtype;

  voxtypePackages = inputs.voxtype.packages.${pkgs.stdenv.hostPlatform.system};
  voxtypePkg = voxtypePackages.${cfg.variant};

  models = {
    tiny = builtins.fetchurl {
      url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin";
      sha256 = "sha256-vgfgSOHlma1GNByNKhNWRQl6U4IhZ4t6zdGxkZxuGyE=";
    };
    "tiny.en" = builtins.fetchurl {
      url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin";
      sha256 = "sha256-kh5M+Ghv3Zk9zQgaXaW2w2W/3hFi5ysI11rHUomSCx8=";
    };
    small = builtins.fetchurl {
      url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin";
      sha256 = "sha256-G+OpsgY4Z7k35k4ux0gzZKeZF+FX+pjF2UtcH//qmHs=";
    };
  };

  defaultSettings = builtins.fromTOML (builtins.readFile "${inputs.voxtype}/config/default.toml");

  # Engine-specific settings, deep-merged onto the upstream defaults.
  engineSettings =
    if cfg.engine == "parakeet" then
      {
        engine = "parakeet";
        parakeet = {
          model = cfg.parakeetModel;
          inherit (cfg) streaming;
        };
      }
    else
      {
        engine = "whisper";
        whisper = {
          language = cfg.whisperLanguage;
          model = toString models.${cfg.whisperModel};
        };
      };

  configToml = (pkgs.formats.toml { }).generate "voxtype-config.toml" (
    lib.recursiveUpdate defaultSettings (
      lib.recursiveUpdate engineSettings {
        hotkey.enabled = false;
        output = {
          mode = "type";
          fallback_to_clipboard = true;
          notification.on_transcription = false;
        };
      }
    )
  );
in
{
  options.spaces.voxtype = {
    variant = lib.mkOption {
      type = lib.types.enum (builtins.attrNames voxtypePackages);
      default = "vulkan";
      description = ''
        voxtype package variant to install. Use a `parakeet*` variant
        (e.g. "parakeet-cuda") when engine = "parakeet"; the default
        "vulkan" build only supports the whisper engine.
      '';
    };

    engine = lib.mkOption {
      type = lib.types.enum [
        "whisper"
        "parakeet"
      ];
      default = "whisper";
      description = "Transcription engine.";
    };

    streaming = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable Parakeet cache-aware streaming: live partial transcripts
        while recording, final transcript typed on release. Only takes
        effect when engine = "parakeet".
      '';
    };

    parakeetModel = lib.mkOption {
      type = lib.types.str;
      default = "parakeet-unified-en-0.6b";
      description = ''
        Parakeet model name (resolved from ~/.local/share/voxtype/models/,
        downloaded on first use) or an absolute path to a model directory.
        Streaming requires a streaming-capable model (TDT v3 family with
        tokenizer.model), of which this is the default.
      '';
    };

    whisperModel = lib.mkOption {
      type = lib.types.enum (builtins.attrNames models);
      default = "small";
      description = "Whisper model size for voice-to-text (engine = whisper).";
    };
    whisperLanguage = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      description = "Whisper language (e.g. 'en', 'auto').";
    };
  };

  imports = [
    inputs.voxtype.nixosModules.default
    # On-screen recording indicator (small red dot); replaces the
    # voice-recording notifications. Reads `voxtype status --follow`,
    # which works because state_file = "auto" is set above.
    ./voxtype-indicator.nix
  ];

  config = {
    assertions = [
      {
        assertion = cfg.engine == "parakeet" -> lib.hasPrefix "parakeet" cfg.variant;
        message = ''
          spaces.voxtype.engine = "parakeet" requires a parakeet-capable
          package variant. Set spaces.voxtype.variant to one of:
          ${lib.concatStringsSep ", " (builtins.filter (lib.hasPrefix "parakeet") (builtins.attrNames voxtypePackages))}.
        '';
      }
    ];

    programs.voxtype = {
      enable = true;
      package = voxtypePkg;
    };

    # System-wide default config; users can override via ~/.config/voxtype/config.toml.
    environment.etc."xdg/voxtype/config.toml".source = configToml;

    # systemd user service — starts voxtype daemon with the graphical session.
    systemd.user.services.voxtype = {
      description = "VoxType push-to-talk voice-to-text daemon";
      documentation = [ "https://voxtype.io" ];
      partOf = [ "graphical-session.target" ];
      after = [
        "graphical-session.target"
        "pipewire.service"
        "pipewire-pulse.service"
      ];
      path = [ pkgs.which ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${voxtypePkg}/bin/voxtype -c ${configToml} daemon";
        Restart = "on-failure";
        RestartSec = 5;
      };
      wantedBy = [ "graphical-session.target" ];
    };
  };
}
