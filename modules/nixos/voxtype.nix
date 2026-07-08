# Voice-to-text via voxtype (push-to-talk / toggle mode)
#
# Installs voxtype, writes a system-wide default config, and creates a
# systemd user service that starts with the graphical session. The service
# prefers a user override at ~/.config/voxtype/config.toml (written by the
# voxtype-tuner "Apply" action) over the generated config, so tuning takes
# effect on a plain `systemctl --user restart voxtype` — no nixos-rebuild.
#
# Three engines are supported:
#   - whisper  (default): whisper.cpp, batch transcription. Uses the
#     `vulkan` package variant (AMD/Intel GPU, no CUDA) and a Nix-fetched
#     ggml model so the closure is fully offline.
#   - parakeet: NVIDIA FastConformer via ONNX. With `streaming = true`
#     voxtype emits live partial transcripts during recording and types
#     the final transcript on release. Requires a parakeet-feature build
#     (one of the `parakeet*` package variants) and a streaming-capable
#     model directory, which voxtype downloads on first use into
#     ~/.local/share/voxtype/models/.
#   - nemotron: NVIDIA's multilingual (40-locale) cache-aware streaming
#     ASR export, driven through parakeet-rs's `Nemotron` type. Reuses the
#     `parakeet` ONNX feature, so it also needs a `parakeet*` variant. Its
#     ~2.6 GB model is Nix-fetched (see `nemotronModels`) so a nemotron host
#     stays offline like whisper — unlike parakeet, voxtype ships no
#     first-use downloader for it. CPU-only (fp32) upstream today.
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

  # The onnx-cuda voxtype wrapper omits libcudart/libcublas from its
  # LD_LIBRARY_PATH, so the CUDA execution provider fails to initialise
  # and the daemon silently falls back to CPU. Inject them for cuda
  # variants (the wrapper preserves an inherited LD_LIBRARY_PATH). The
  # other CUDA libs the EP needs (cudnn/cufft/curand/nvrtc) are already
  # in the wrapper's path.
  isCudaVariant = lib.hasInfix "cuda" cfg.variant;
  cudaLibraryPath = lib.makeLibraryPath [
    pkgs.cudaPackages.cuda_cudart
    pkgs.cudaPackages.libcublas
  ];

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

  # Nemotron models, Nix-fetched so a nemotron host's closure stays offline
  # exactly like the whisper ggml models above. Shared verbatim with the
  # voxtype-tuner package (packages/voxtype-tuner/default.nix), which drives the
  # same engine from its Transcribe button — factored into one file so the
  # ~2.6 GB git-LFS fetch is defined once, not duplicated.
  nemotronModels = import ./nemotron-models.nix { inherit pkgs lib; };

  defaultSettings = builtins.fromTOML (builtins.readFile "${inputs.voxtype}/config/default.toml");

  # Engine-specific settings, deep-merged onto the upstream defaults.
  engineSettings =
    if cfg.engine == "parakeet" then
      {
        engine = "parakeet";
        parakeet = {
          model = cfg.parakeetModel;
          inherit (cfg) streaming;
          # voxtype's own streaming-context defaults (1.5/0.5/0.5) violate
          # parakeet-rs 0.3.5's constraint that each value map to a
          # mel-frame count (round(secs * 100)) divisible by 8, so the
          # daemon refuses to start. Use the crate's blessed profile
          # (560/56/56 frames). Left context is lookback (no added
          # latency); right context (0.56s) is the lookahead delay.
          streaming_chunk_secs = 0.56;
          streaming_left_context_secs = 5.6;
          streaming_right_context_secs = 0.56;
        };
      }
    else if cfg.engine == "nemotron" then
      {
        engine = "nemotron";
        nemotron = {
          # A known registry name resolves to the Nix-fetched offline model
          # directory; any other value passes through as an absolute path or a
          # name voxtype resolves under ~/.local/share/voxtype/models/.
          model = toString (nemotronModels.${cfg.nemotronModel} or cfg.nemotronModel);
          target_lang = cfg.nemotronTargetLang;
          inherit (cfg) streaming;
        };
      }
    else
      {
        engine = "whisper";
        whisper = {
          language = cfg.whisperLanguage;
          model = toString models.${cfg.whisperModel};
          initial_prompt = cfg.initialPrompt;
        };
      };

  # Voice Activity Detection: reject silence-only / too-quiet takes before
  # they reach the transcription engine. This both stops Whisper
  # hallucinating text out of silence and gives the bar indicator an
  # observable "no speech" signal (a rejected take steps recording→idle
  # without ever entering transcribing).
  #
  # backend MUST be "energy": it is pure-Rust (src/vad/energy.rs, not
  # feature-gated) and needs no model, so it runs on the shipped vulkan
  # build and keeps the closure offline. "auto" would select Whisper/Silero
  # VAD for the whisper engine and download ggml-silero-vad.bin on first
  # use, breaking the offline guarantee.
  vadSettings = lib.optionalAttrs cfg.vad.enable {
    vad = {
      enabled = true;
      backend = "energy";
      inherit (cfg.vad) threshold;
      min_speech_duration_ms = cfg.vad.minSpeechMs;
    };
  };

  configToml = (pkgs.formats.toml { }).generate "voxtype-config.toml" (
    lib.recursiveUpdate defaultSettings (
      lib.recursiveUpdate engineSettings (
        lib.recursiveUpdate {
          hotkey.enabled = false;
          # We ship no OSD frontend (voxtype-osd-*) and use our own
          # indicator; disable voxtype's built-in OSD so the daemon doesn't
          # crash-loop trying to spawn a missing binary.
          osd.enabled = false;
          output = {
            mode = "type";
            fallback_to_clipboard = true;
            notification.on_transcription = false;
          };
        } vadSettings
      )
    )
  );

  # Start the daemon against a user override at
  # $XDG_CONFIG_HOME/voxtype/config.toml when one exists (the voxtype-tuner
  # "Apply" action writes it), else against the Nix-generated config. The
  # existence probe is load-bearing: `voxtype -c <missing>` silently runs on
  # voxtype's built-in defaults (src/config/load.rs), which would re-enable
  # the hotkey grab and the OSD we disable above.
  #
  # voxtype does not merge config files — an override layers over voxtype's
  # *built-in* defaults, not over the generated config, so a partial
  # hand-written override sheds the settings above. The tuner always writes
  # a complete file (seeded from /etc/xdg/voxtype/config.toml).
  #
  # Failure mode: a malformed override makes the daemon exit at startup and
  # Restart=on-failure loops it — the same as running voxtype by hand with a
  # bad config. Deliberately no silent fallback to the generated config; a
  # half-applied config is worse than a visibly failing unit. Escape hatch:
  # fix or delete the override, then `systemctl --user restart voxtype`.
  #
  # `voxtype` is invoked by name, pinned via the unit's `path` below, so
  # this script's closure stays tiny (just the generated TOML): the
  # voxtype-user-override-nix-eval check can realise and read it without
  # building the voxtype package.
  daemonScript = pkgs.writeShellApplication {
    name = "voxtype-daemon";
    text = ''
      user_config="''${XDG_CONFIG_HOME:-$HOME/.config}/voxtype/config.toml"
      config="${configToml}"
      if [ -f "$user_config" ]; then
        config="$user_config"
      fi
      exec voxtype -c "$config" daemon
    '';
  };
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
        "nemotron"
      ];
      default = "whisper";
      description = "Transcription engine.";
    };

    streaming = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable cache-aware streaming: live partial transcripts while
        recording, final transcript typed on release. Only takes effect
        when engine = "parakeet" or engine = "nemotron".
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

    nemotronModel = lib.mkOption {
      type = lib.types.str;
      default = "nemotron-3.5-asr-streaming-0.6b";
      description = ''
        Model for engine = "nemotron". A known registry name (currently only
        "nemotron-3.5-asr-streaming-0.6b") resolves to a Nix-fetched model
        directory baked into the closure, so the host stays offline like the
        whisper engine. Any other value is passed through verbatim — either an
        absolute path to a model directory you provide, or a registry name
        voxtype resolves under ~/.local/share/voxtype/models/ (note: voxtype
        ships no first-use downloader for nemotron, so a bare name only works
        if you have placed the files there yourself).
      '';
    };

    nemotronTargetLang = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      example = "de-DE";
      description = ''
        Target locale for the multilingual nemotron model, as a BCP-47-ish key
        the model's prompt dictionary accepts (e.g. "en-US", "es-ES", "de-DE",
        "ja-JP", "zh-CN"). "auto" lets the model detect the language itself.
        Only takes effect when engine = "nemotron".
      '';
    };

    whisperModel = lib.mkOption {
      type = lib.types.enum (builtins.attrNames models);
      default = "small";
      description = "Whisper model size for voice-to-text (engine = whisper).";
    };
    whisperLanguage = lib.mkOption {
      type = lib.types.either lib.types.str (lib.types.listOf lib.types.str);
      default = "auto";
      example = [
        "en"
        "ru"
      ];
      description = ''
        Whisper language (e.g. 'en', 'auto'). A list of languages enables
        voxtype's multilingual dictation, serialized as a TOML array
        (language = ["en","ru"]).
      '';
    };
    initialPrompt = lib.mkOption {
      type = lib.types.str;
      default = "Voice input from a Spaces OS user dictating to the pi agent. Likely terms: Spaces OS, NixOS, Nix flake, derivation, Quickshell, QML, Wayland, niri, systemd, llama-swap, pi agent, Claude, Rust, TypeScript, Python, async, struct, enum, GitHub, pull request, commit.";
      description = ''
        Whisper decoder priming text (whisper.cpp `initial_prompt`). Biases
        transcription toward domain vocabulary. Keep it short: whisper's
        prompt budget is ~224 tokens and over-stuffing it degrades accuracy.
        Ignored by the parakeet engine.
      '';
    };
    vad = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Enable voxtype's energy-based Voice Activity Detection. Recordings
          with no detected speech — silence, an accidental tap, a too-quiet
          mic — are rejected before transcription. This prevents Whisper from
          hallucinating text out of silence and gives the bar indicator a
          signal to flag a rejected take ("no speech detected").

          Uses the pure-Rust "energy" backend (no model download), so it
          works on the default vulkan build and keeps the closure offline.
        '';
      };
      threshold = lib.mkOption {
        type = lib.types.float;
        default = 0.4;
        description = ''
          Energy-VAD speech-detection threshold (0.0–1.0). Higher rejects
          more aggressively (demands louder / clearer speech); lower is more
          permissive. voxtype's own default is 0.5; we err slightly more
          sensitive (0.4) so quiet/distant speech is less likely to be wrongly
          dropped. Raise it if background noise is slipping through as "speech",
          lower it if quiet-but-real dictation is still being dropped.
        '';
      };
      minSpeechMs = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 100;
        description = ''
          Minimum detected speech duration (ms) for a take to be kept.
          Recordings with less speech than this are rejected as no-speech.
        '';
      };
    };
  };

  imports = [ inputs.voxtype.nixosModules.default ];

  config = {
    assertions = [
      {
        assertion =
          (cfg.engine == "parakeet" || cfg.engine == "nemotron") -> lib.hasPrefix "parakeet" cfg.variant;
        message = ''
          spaces.voxtype.engine = "${cfg.engine}" requires a parakeet-capable
          package variant (nemotron reuses the parakeet ONNX feature). Set
          spaces.voxtype.variant to one of:
          ${lib.concatStringsSep ", " (builtins.filter (lib.hasPrefix "parakeet") (builtins.attrNames voxtypePackages))}.
        '';
      }
    ];

    programs.voxtype = {
      enable = true;
      package = voxtypePkg;
    };

    # Reference copy of the generated config, read by the voxtype-tuner as
    # "system defaults" ($VOXTYPE_TUNER_DEFAULT_CONFIG fallback). voxtype
    # itself never reads /etc/xdg — its native system fallback is
    # /etc/voxtype/config.toml (src/config/root.rs SYSTEM_PATH), and the
    # daemon below is started with an explicit -c anyway. User overrides are
    # honored by daemonScript, not through this file.
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
      # voxtypePkg first: daemonScript execs `voxtype` by name (see its
      # comment for why it is not an absolute store path).
      path = [
        voxtypePkg
        pkgs.which
      ];
      environment = lib.optionalAttrs isCudaVariant {
        LD_LIBRARY_PATH = cudaLibraryPath;
      };
      serviceConfig = {
        Type = "simple";
        ExecStart = lib.getExe daemonScript;
        Restart = "on-failure";
        RestartSec = 5;
      };
      wantedBy = [ "graphical-session.target" ];
    };
  };
}
