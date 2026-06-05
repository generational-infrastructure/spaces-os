# Model-directive launch contract test.
#
# Proves backend.launchBackground(prompt, {model}) applies the requested
# model to the pi worker BEFORE the prompt turn runs — the race the
# awaited set_model fix closes. The mock LLM serves a multi-model list
# (MOCK_MODELS_JSON); pi's default is deliberately a different model, so
# the logged /v1/chat/completions request carrying the launched model is
# a sharp regression guard for the set_model-vs-send race.
#
# Reuses the pi-session-quick-launch stubs and mock so the launch
# harness stays single-sourced. No VM, no compositor. ~10-20s.
{ pkgs, inputs, ... }:
let
  piPkg = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;
  harness = ../pi-session-quick-launch;
in
pkgs.runCommand "pi-session-quick-launch-model-directive-test"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.quickshell
      pkgs.coreutils
      pkgs.bash
      pkgs.qt6.qtbase
      pkgs.qt6.qtdeclarative
    ];
    extDir = ../../modules/nixos/pi-chat/extensions;
    pluginDir = ../../programs/pi-chat;
  }
  ''
    set -euo pipefail
    work=$TMPDIR/work
    mkdir -p "$work"
    export QT_PLUGIN_PATH=${pkgs.qt6.qtbase}/lib/qt-6/plugins
    # PiChatBackend instantiates PiExecutor, which imports QtWebSockets — it
    # lives outside quickshell's bundled QML path, so add it explicitly.
    export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml:${pkgs.qt6.qtwebsockets}/lib/qt-6/qml
    python3 ${./driver.py} \
      ${pkgs.lib.getExe piPkg} \
      ${pkgs.lib.getExe pkgs.quickshell} \
      ${harness}/mock-llm.py \
      "$extDir" \
      ${./.} \
      ${harness} \
      "$pluginDir" \
      "$work"
    touch $out
  ''
