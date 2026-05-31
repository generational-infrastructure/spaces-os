# Voice-to-text via voxtype (push-to-talk / toggle mode)
#
# Installs voxtype with Vulkan acceleration (AMD/Intel GPU, no CUDA),
# writes a system-wide default config, and creates a systemd user
# service that starts with the graphical session.
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
  voxtypePkg = inputs.voxtype.packages.${pkgs.stdenv.hostPlatform.system}.vulkan;

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

  cfg = config.spaces.voxtype;

  defaultSettings = builtins.fromTOML (builtins.readFile "${inputs.voxtype}/config/default.toml");

  configToml = (pkgs.formats.toml { }).generate "voxtype-config.toml" (
    lib.recursiveUpdate defaultSettings {
      hotkey.enabled = false;
      whisper = {
        language = cfg.whisperLanguage;
        model = toString models.${cfg.whisperModel};
      };
      output = {
        mode = "type";
        fallback_to_clipboard = true;
        notification.on_transcription = false;
      };
    }
  );
in
{
  options.spaces.voxtype = {
    whisperModel = lib.mkOption {
      type = lib.types.enum (builtins.attrNames models);
      default = "small";
      description = "Whisper model size for voice-to-text.";
    };
    whisperLanguage = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      description = "Whisper language (e.g. 'en', 'auto').";
    };
  };

  imports = [ inputs.voxtype.nixosModules.default ];

  config = {
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
