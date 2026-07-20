# voxtype-tuner: a standalone `bin/voxtype-tuner` built purely and offline,
# with no runtime uv, no runtime network, and no runtime LD hack for the slint
# native lib. Ported from the predecessor repo (distro), where this was the
# Slint tuner package. Spaces OS owns the voxtype NixOS module, so it lives here.
#
# The dev flow (run.sh + the `.#voxtype-tuner` dev shell in
# devshells/voxtype-tuner.nix) covers MCP-driven headless work, with no uv. This
# file is the packaged, windowed application. Two things make it non-obvious:
#
#   1. slint ships only as a beta manylinux wheel with no RPATH, so we vendor
#      the BASE wheel and let autoPatchelfHook rewrite it, after which the
#      slint extension resolves its bundled libs (slint.libs/, RPATH
#      $ORIGIN/../slint.libs) with no LD_LIBRARY_PATH at runtime. Only the
#      windowing libs slint dlopen()s to open a window (which autoPatchelf
#      cannot see) and a fontconfig config still go through the wrapper.
#
#   2. app.py resolves ui/app.slint relative to its own __file__ one dir up, so
#      the wheel must carry ui/app.slint beside the package. See the
#      force-include in pyproject.toml.
{
  inputs,
  pkgs,
  spaces-logos ? pkgs.callPackage ../spaces-logos { },
  ...
}:
let
  inherit (pkgs) lib;
  python = pkgs.python313;

  # Launcher icon composed at build time from the canonical Spaces mark in the
  # shared `spaces-logos` FOD, so a desktop launcher shows the app with the
  # Spaces logo. Same recipe as pi-chat-desktop-entries: the black-filled mark
  # on a white tile. markColor recolors the lifted <path/> (a no-op while it
  # stays black) so tileColor/markColor remain a two-knob contrast switch.
  tileColor = "#ffffff";
  markColor = "#000000";
  tileSize = 512;
  cornerRadius = 100;
  # Mark centered at ~62% tile width. Height follows the 252:219 viewBox
  # aspect, so only markWidth needs touching to rescale.
  markWidth = 320;
  markHeight = markWidth * 219 / 252;
  markX = (tileSize - markWidth) / 2;
  markY = (tileSize - markHeight) / 2;

  iconSizes = [
    16
    32
    48
    64
    128
    256
    512
  ];
  largestIconSize = toString (lib.foldl' lib.max 0 iconSizes);

  # The tuner shells out to a `voxtype` binary to download and run models. A bare
  # `voxtype` from PATH resolves to the whisper-only build, so parakeet models are
  # rejected at the feature gate ("Parakeet feature not enabled"). Point the tuner
  # at the voxtype input's CPU `parakeet` build instead: it carries the parakeet
  # feature AND still runs whisper, so one binary covers both engines the tuner
  # offers. `parakeet-cuda` is the GPU-gated variant. This CPU one keeps the
  # package pure/offline. Wired in via --set-default below so a test-supplied
  # $VOXTYPE_BIN still wins.
  voxtypeParakeet = inputs.voxtype.packages.${pkgs.stdenv.hostPlatform.system}.parakeet;

  # The nemotron engine has no first-use downloader (unlike whisper/parakeet), so
  # its ~2.6 GB ONNX model must be provisioned for the Transcribe button to work
  # offline. Reuse the SAME Nix-fetched model derivation the voxtype NixOS module
  # feeds its daemon, so the git-LFS fetch is defined once. Here it is pinned
  # into the wrapper via --set-default below and read back as VOXTYPE_NEMOTRON_MODEL.
  # This is what adds ~2.6 GB to the tuner's runtime closure.
  nemotronModel =
    (import ../../modules/nixos/nemotron-models.nix { inherit pkgs; })
    ."nemotron-3.5-asr-streaming-0.6b";

  # `import slint` eagerly initialises fontconfig, which aborts the process
  # ("Cannot load default config file") without a readable config. It is needed
  # both at runtime and during the slint wheel's own pythonImportsCheck, so
  # point FONTCONFIG_FILE at a minimal one in both places. Inter is the
  # styleguide face (ui/theme.slint sets font-family "Inter") and DM Mono the
  # mono face (font-mono). Shipping them via fontconfig keeps the fonts out of
  # the repo and the wheel. The dev loop falls back to DejaVu, which the
  # styleguide accepts.
  fontsConf = pkgs.makeFontsConf {
    fontDirectories = [
      pkgs.dejavu_fonts
      pkgs.inter
      pkgs.dm-mono
    ];
  };

  # Default sample so a fresh tuner is instantly transcribable without recording
  # first. whisper.cpp's samples/jfk.wav: a public-domain ~11s JFK speech clip
  # (16 kHz mono), MIT-distributed with whisper.cpp. Fetched into the store
  # (fixed-output, so the build stays pure and offline) and handed to the app by
  # store path via the wrapper below. Deliberately NOT committed into the repo.
  sampleWav = pkgs.fetchurl {
    url = "https://github.com/ggerganov/whisper.cpp/raw/v1.7.4/samples/jfk.wav";
    hash = "sha256-Wd+5pKyzb+Kir/wUusvuKSD/Q1yxPMMUoIwT9munhg4=";
  };

  # slint publishes per-arch manylinux wheels (x86_64 and aarch64, with
  # different glibc floors). Select by host platform; meta.platforms below
  # mirrors this table, and the devshell keys its version-matched slint-dev
  # wheel off the same systems.
  slintWheels = {
    x86_64-linux = {
      platform = "manylinux_2_35_x86_64";
      hash = "sha256-fbky0bNk4on0lDKmzQk20BS0Yfh6OGo14kkBHq4dcsI=";
    };
    aarch64-linux = {
      platform = "manylinux_2_31_aarch64";
      hash = "sha256-P4lucAWemqfDMSknV2hjiKYtStRCw7E1uO9VYAGl9kc=";
    };
  };

  # Base slint wheel, NOT slint[dev]: the dev wheel only carries the extra
  # MCP/testing binary used by the headless run.sh flow, which the packaged
  # app does not need. This is a fixed-output derivation, so the build stays
  # pure and offline. It is a cp311/abi3 wheel: abi3 is CPython's stable ABI,
  # forward-compatible from its cp311 floor, so it imports cleanly under the
  # repo-default python313. The nixpkgs wheel installer ignores compat tags and
  # the host glibc is newer than the wheels' manylinux_2_3x floors.
  slint = python.pkgs.buildPythonPackage {
    pname = "slint";
    version = "1.17.0b2";
    format = "wheel";
    src = pkgs.fetchPypi {
      pname = "slint";
      version = "1.17.0b2";
      format = "wheel";
      dist = "cp311";
      python = "cp311";
      abi = "abi3";
      inherit (slintWheels.${pkgs.stdenv.hostPlatform.system}) platform hash;
    };
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    # Minimal: the wheel bundles ~24 libs under slint.libs/. These cover the
    # few the top-level extension links directly. autoPatchelf then reports 0
    # unsatisfied deps and pythonImportsCheck imports cleanly.
    buildInputs = [
      pkgs.stdenv.cc.cc.lib
      pkgs.expat
      pkgs.glib
      pkgs.zlib
    ];
    # pythonImportsCheck imports slint, which inits fontconfig. Give it a config
    # so the check verifies the autoPatchelf'd wheel instead of aborting.
    env.FONTCONFIG_FILE = "${fontsConf}";
    pythonImportsCheck = [ "slint" ];
  };

  # slint's .run() dlopen()s these to open a window, and autoPatchelf can't see a
  # dlopen, so they must be on LD_LIBRARY_PATH at launch.
  windowLibs = [
    pkgs.libGL
    pkgs.libxkbcommon
    pkgs.wayland
    pkgs.libx11
    pkgs.libxcursor
    pkgs.libxi
    pkgs.libxrandr
  ];
in
python.pkgs.buildPythonApplication {
  pname = "voxtype-tuner";
  version = "0.1.0";
  pyproject = true;

  # The wheel build and the in-build pytest suite. The dev venv, run.sh and
  # default.nix stay out so doc/nix edits don't churn the build.
  src = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./pyproject.toml
      ./README.md
      ./voxtype_tuner
      ./ui
      ./tests
    ];
  };

  build-system = [ python.pkgs.hatchling ];

  # Stock nixpkgs audio deps, they already wire portaudio/libsndfile, so don't
  # hand-package them. slint is the vendored base wheel above.
  dependencies = [
    slint
    python.pkgs.sounddevice
    python.pkgs.soundfile
    python.pkgs.numpy
  ];

  # pyproject pins slint[dev]. We ship plain slint, so skip the dist-info
  # Requires-Dist validation that would otherwise reject the substitution.
  dontCheckRuntimeDeps = true;

  nativeBuildInputs = [
    pkgs.makeWrapper
    pkgs.copyDesktopItems
    pkgs.librsvg
  ];

  # Freedesktop launcher entry. Exec is the bare installed binary name so
  # launchers resolve it via PATH, independent of the store path. icon matches
  # the hicolor basename installed in postInstall below.
  desktopItems = [
    (pkgs.makeDesktopItem {
      name = "voxtype-tuner";
      desktopName = "Voice Tuner";
      genericName = "Speech-to-text tuner";
      comment = "Tune voxtype speech-to-text models and dictation settings";
      exec = "voxtype-tuner";
      icon = "voxtype-tuner";
      terminal = false;
      # One main category (AudioVideo) plus the Audio qualifier, which the menu
      # spec designates as an additional category used *with* AudioVideo, so
      # the entry lands once under Sound & Video, not twice as two main cats.
      categories = [
        "AudioVideo"
        "Audio"
      ];
      keywords = [
        "voice"
        "dictation"
        "voxtype"
        "speech"
      ];
    })
  ];

  # Run the pytest suite inside the sandbox. The pure helpers (argv builder,
  # transcribe/download parsing, recorder state machine, take persistence,
  # terminal lifecycle) need nothing special. test_app additionally imports the
  # native slint lib, guarded by pytest.importorskip("slint"). Since slint IS
  # a dependency here it runs, driving configure() against a fake window with
  # no real event loop or display. The lifecycle subprocess regressions skip
  # themselves here (they need the slint-dev wheel's headless backend, which
  # this package deliberately does not ship).
  nativeCheckInputs = [
    python.pkgs.pytestCheckHook
    pkgs.bash
  ];

  preCheck = ''
    # `import slint` eagerly inits fontconfig and aborts ("Cannot load default
    # config file") without a readable config. test_app's importorskip would
    # then crash the interpreter rather than skip. Point it at the same minimal
    # config the wrapper uses at runtime.
    export FONTCONFIG_FILE=${fontsConf}

    # transcribe/download tests write throwaway fake `voxtype` scripts with a
    # `#!/usr/bin/env bash` shebang and exec them. The build sandbox has no
    # /usr/bin/env (only /bin/sh), so rewrite that shebang to an absolute bash
    # in the test sources. On a normal host with /usr/bin/env the committed
    # tests stay portable for the dev-venv flow.
    for f in tests/*.py; do
      substituteInPlace "$f" \
        --replace-quiet "#!/usr/bin/env bash" "#!${pkgs.bash}/bin/bash"
    done
  '';

  # Compose the hicolor launcher icon. copyDesktopItems runs in postInstallHooks
  # (after this), so the .desktop file lands independently. This only handles the
  # icon. Lift the mark out of the canonical SVG (a single self-closing <path/>)
  # and recolor it for contrast on the tile, then rasterize to each hicolor size.
  postInstall = ''
    mark=$(grep -o '<path[^>]*/>' ${spaces-logos}/spaces-logo.svg \
      | sed 's/fill="black"/fill="${markColor}"/')
    [ -n "$mark" ] || { echo "no <path/> found in spaces-logo.svg" >&2; exit 1; }

    cat > voxtype-tuner.svg <<EOF
    <svg width="${toString tileSize}" height="${toString tileSize}" viewBox="0 0 ${toString tileSize} ${toString tileSize}" xmlns="http://www.w3.org/2000/svg">
      <rect width="${toString tileSize}" height="${toString tileSize}" rx="${toString cornerRadius}" fill="${tileColor}"/>
      <svg x="${toString markX}" y="${toString markY}" width="${toString markWidth}" height="${toString markHeight}" viewBox="0 0 252 219">
        $mark
      </svg>
    </svg>
    EOF

    install -Dm644 voxtype-tuner.svg $out/share/icons/hicolor/scalable/apps/voxtype-tuner.svg
    for size in ${toString iconSizes}; do
      rsvg-convert -w $size -h $size voxtype-tuner.svg -o voxtype-tuner-$size.png
      install -Dm644 voxtype-tuner-$size.png \
        $out/share/icons/hicolor/''${size}x''${size}/apps/voxtype-tuner.png
    done
  '';

  # The package __init__ defaults SLINT_BACKEND to "headless" for the MCP dev
  # flow (run.sh), so left alone the packaged binary would render offscreen and
  # never open a window. Default it to the winit backend instead (the desktop
  # app's whole reason to exist), while --set-default still lets a caller force
  # headless for testing.
  #
  # wl-clipboard goes on PATH so the transcript's Copy button finds `wl-copy`
  # at runtime (app.py shells out to it, overridable via WL_COPY_BIN).
  postFixup = ''
    wrapProgram $out/bin/voxtype-tuner \
      --set FONTCONFIG_FILE ${fontsConf} \
      --set-default SLINT_STYLE cupertino \
      --set-default SLINT_BACKEND winit \
      --set-default VOXTYPE_TUNER_SAMPLE_WAV ${sampleWav} \
      --set-default VOXTYPE_BIN ${voxtypeParakeet}/bin/voxtype \
      --set-default VOXTYPE_NEMOTRON_MODEL ${nemotronModel} \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.wl-clipboard ]} \
      --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath windowLibs}
  '';

  # Validate the launcher entry and its icon inside the build, so a broken
  # SVG lift or a name mismatch between the .desktop `icon` and the installed
  # hicolor basename fails the build instead of shipping a blank launcher tile.
  doInstallCheck = true;
  nativeInstallCheckInputs = [
    pkgs.desktop-file-utils
    pkgs.imagemagick
  ];
  installCheckPhase = ''
    runHook preInstallCheck

    # pytestCheckHook wires its pytest run into installCheckPhase, which this
    # custom phase overrides, so invoke it explicitly here, or the suite in
    # nativeCheckInputs/preCheck would be silently skipped and a failing test
    # ship green. `runHook preInstallCheck` above already ran its cache /
    # bytecode / import preamble. This is the actual pytest.
    pytestCheckPhase

    fail() {
      echo "installCheck: $1" >&2
      exit 1
    }

    f=$out/share/applications/voxtype-tuner.desktop
    [ -f "$f" ] || fail "missing desktop entry $f"
    desktop-file-validate "$f" || fail "desktop-file-validate rejected $f"

    [ -f $out/share/icons/hicolor/scalable/apps/voxtype-tuner.svg ] \
      || fail "missing scalable icon"

    for size in ${toString iconSizes}; do
      png=$out/share/icons/hicolor/''${size}x''${size}/apps/voxtype-tuner.png
      [ -f "$png" ] || fail "missing $png"
      dims=$(magick identify -format '%wx%h' "$png")
      [ "$dims" = "''${size}x''${size}" ] \
        || fail "$png is $dims, expected ''${size}x''${size}"
    done

    # Contrast guard: %k>1 catches a fully flat render. The two mean-luminance
    # probes catch a dropped tile rect (flattens near-black) and a mark
    # recolored to the tile color (flattens near-white).
    big=$out/share/icons/hicolor/${largestIconSize}x${largestIconSize}/apps/voxtype-tuner.png
    colors=$(magick "$big" -format '%k' info:)
    [ "$colors" -gt 1 ] || fail "icon is a single flat color"
    mean=$(magick "$big" -background black -flatten -alpha off -colorspace gray \
      -format '%[fx:mean]' info:)
    awk -v m="$mean" 'BEGIN { exit !(m > 0.02) }' \
      || fail "icon is (near) solid black: mean luminance $mean"
    mean=$(magick "$big" -background white -flatten -alpha off -colorspace gray \
      -format '%[fx:mean]' info:)
    awk -v m="$mean" 'BEGIN { exit !(m < 0.98) }' \
      || fail "icon is (near) solid white: mean luminance $mean"

    runHook postInstallCheck
  '';

  # Expose the vendored base wheel and the dlopen'd window libs so the local dev
  # shell (devshells/voxtype-tuner.nix) can pair the SAME base wheel with the
  # version-matched slint-dev wheel (the MCP/headless companion) and reuse the
  # window libs for its --window path, without re-deriving either or risking
  # version skew. passthru attrs are not build inputs, so `nix build
  # .#voxtype-tuner` stays byte-identical.
  passthru = { inherit slint windowLibs; };

  meta = {
    description = "Voice Tuner: Slint desktop tuner for voxtype STT";
    mainProgram = "voxtype-tuner";
    # Mirrors the slint wheel table above: slint publishes manylinux wheels
    # for exactly these Linux systems, so declare the constraint rather than
    # fail late in fetchPypi/autoPatchelf.
    platforms = builtins.attrNames slintWheels;
  };
}
