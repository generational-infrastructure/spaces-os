# Voice-to-text via voxtype (push-to-talk / toggle mode).
#
# The daemon runs through the per-app sandbox model
# (`services.spaces.apps.voxtype-daemon`): isolated $HOME, hardened
# systemd baseline, `audio.record` for the PipeWire mic socket,
# `wayland` for the compositor connection, and crucially
# `waylandSandbox = false` so the daemon can bind the
# virtual-keyboard protocol that drives type-mode output (otherwise
# wayland-app-context's security-context-v1 wrap would filter it).
#
# The user-facing CLI (`voxtype record toggle`) stays on the host
# PATH and is invoked from the niri keybind; it locates the daemon
# via systemd / pgrep and sends SIGUSR1/2. Signals cross the sandbox
# boundary because we don't isolate the PID namespace.
#
# Keybinding: Mod+S  (defined in niri.nix)
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

    # Per-app sandbox declaration. The launcher generated from this
    # entry (`app-run-voxtype-daemon`) is what the systemd user unit
    # below execs — same hardened baseline as every other app, plus
    # the voxtype-specific bits.
    services.spaces.apps.voxtype-daemon = {
      package = voxtypePkg;
      args = [
        "-c"
        "${configToml}"
        "daemon"
      ];
      # voxtype writes its pid / voxtype.lock / cancel / trigger files to
      # $XDG_RUNTIME_DIR/voxtype (hardcoded in the daemon). It must be a
      # real, writable, host-shared dir: the Mod+S `voxtype record toggle`
      # CLI runs outside the sandbox and signals the daemon through it.
      runtimeDir = "voxtype";
      permissions.granted = [
        "audio.record"
        "wayland"
      ];
      # The daemon types into the focused window via the
      # virtual-keyboard Wayland protocol; the security-context wrap
      # would filter that out. Skip it. The Wayland socket is still
      # bound; only the wayland-app-context invocation is dropped.
      waylandSandbox = false;
      # Bigger than the 2G default — Whisper inference holds the
      # model in RAM and can spike during transcription.
      resources.memoryHigh = "4G";
    };

    # The voxtype daemon's systemd user unit, rerouted through the
    # apps launcher. ExecStart is the generated `app-run-voxtype-daemon`
    # script; everything inside it runs sandboxed.
    systemd.user.services.voxtype = {
      description = "VoxType push-to-talk voice-to-text daemon";
      documentation = [ "https://voxtype.io" ];
      partOf = [ "graphical-session.target" ];
      after = [
        "graphical-session.target"
        "pipewire.service"
        "pipewire-pulse.service"
      ];
      serviceConfig = {
        Type = "simple";
        # The launcher binary lands on PATH via the apps module's
        # environment.systemPackages, so this resolves to its
        # /run/current-system/sw/bin/... path.
        ExecStart = "/run/current-system/sw/bin/app-run-voxtype-daemon";
        Restart = "on-failure";
        RestartSec = 5;
      };
      wantedBy = [ "graphical-session.target" ];
    };
  };
}
