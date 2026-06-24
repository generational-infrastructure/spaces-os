# Quick-launch background-agent contract test.
#
# Drives the real PiChatBackend through headless quickshell against a REAL
# pi-sessiond executor (bun, embedding pi via its SDK) backed by a mock LLM,
# and asserts the Mod+/ fire-and-forget path: backend.launchBackground(prompt)
# creates exactly ONE session pinned to the "host" executor WHILE THE PANEL
# IS HIDDEN (create_session over the WebSocket), the daemon runs the turn and
# streams the reply back, and a stub `notify-send` records exactly one
# "Agent finished" notification on completion.
#
# The executor topology is injected as JSON via $SPACES_PI_CHAT_EXECUTORS
# (the panel's test seam; the root-owned /etc/spaces/pi-chat.json can't be
# written in the build sandbox). The daemon's per-command bash confinement
# wrapper is a passthrough stub — no bash tool commands run here.
#
# No VM, no compositor. ~10-30s.
{ pkgs, inputs, ... }:
let
  daemon = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond;
  # Passthrough launcher stubs (no systemd / no kernel Landlock in the build
  # sandbox); real Landlock enforcement is checks/pi-sessiond-landlock.
  stubs = import ../pi-sessiond-sidechannel/launcher-stubs.nix { inherit pkgs; };
  # The per-session child agent dir no longer inherits the daemon's shared
  # provider auth/models, so the child registers `local` itself via the same
  # llama-swap-discover extension production loads (from LLAMA_SWAP_BASE_URL).
  llamaSwapDiscover = builtins.path {
    path = ../../modules/nixos/pi-chat/extensions/llama-swap-discover.ts;
    name = "llama-swap-discover.ts";
  };
in
pkgs.runCommand "pi-session-quick-launch-test"
  {
    meta.platforms = [ "x86_64-linux" ];
    nativeBuildInputs = [
      pkgs.python3
      pkgs.quickshell
      pkgs.coreutils
      pkgs.bash
      pkgs.qt6.qtbase
      pkgs.qt6.qtdeclarative
      pkgs.qt6.qtwebsockets
    ];
    pluginDir = ../../programs/pi-chat;
  }
  ''
    set -euo pipefail
    work=$TMPDIR/work
    mkdir -p "$work"
    export QT_PLUGIN_PATH=${pkgs.qt6.qtbase}/lib/qt-6/plugins
    # PiExecutor imports QtWebSockets, which lives outside quickshell's bundled
    # QML path — add it on both the Qt and the nixpkgs import-path vars.
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml:${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    export NIXPKGS_QT6_QML_IMPORT_PATH=${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    # The daemon requires the Landlock launcher; the passthrough stub stands in
    # (driver.py inherits this via os.environ.copy() into the daemon's env).
    export SPACES_SESSIOND_LANDLOCK_EXEC=${stubs.landlockExec}/bin/pi-landlock-exec
    # The child is spawned by bare name unless told otherwise; point it at the
    # exact pi the daemon re-exports (the launcher execs an absolute path, not a
    # PATH lookup) — same as production, which sets SPACES_SESSIOND_PI_BIN.
    export SPACES_SESSIOND_PI_BIN=${pkgs.lib.getExe' daemon.pi "pi"}
    export SPACES_QL_DISCOVER_EXT=${llamaSwapDiscover}
    python3 ${./driver.py} \
      ${pkgs.lib.getExe daemon} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${./mock-llm.py} \
      ${stubs.systemdRun}/bin/systemd-run \
      ${./.} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
