# Model-picker population contract test.
#
# The panel's header model dropdown is the ONLY surface through which a
# user picks a model, and "the dropdown is empty" was observed in the GUI
# VM while every data-layer probe (session.models, activeModel) was
# healthy — the gap is between the session state and what the NComboBox
# displays when the model list arrives asynchronously after the widget
# was created. So this check stages the REAL NComboBox bound exactly like
# Panel.qml next to the real PiChatBackend, against a REAL pi-sessiond
# (bun, embedding pi via its SDK) whose mock LLM serves a multi-model
# list, and asserts the widget layer: item count, current index, and the
# closed-state display text naming the active model — on first open
# (create_session racing the round-trip) and on a quickshell restart over
# a persisted entry carrying the legacy executor:"" pin (attach path).
#
# Reuses the pi-session-quick-launch mock LLM; bash confinement wrapper
# is a passthrough stub (no bash tool commands run here). No VM, no
# compositor. ~10-30s.
{ pkgs, inputs, ... }:
let
  daemon = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond;
  harness = ../pi-session-quick-launch;
  stub = pkgs.runCommandLocal "systemd-run-stub" { nativeBuildInputs = [ pkgs.bash ]; } ''
    install -Dm755 ${../pi-sessiond-sidechannel/systemd-run-stub} $out/bin/systemd-run
    patchShebangs $out/bin/systemd-run
  '';
  landlockExecStub =
    pkgs.runCommandLocal "pi-landlock-exec-stub" { nativeBuildInputs = [ pkgs.bash ]; }
      ''
        install -Dm755 ${../pi-sessiond-sidechannel/landlock-exec-stub} $out/bin/pi-landlock-exec
        patchShebangs $out/bin/pi-landlock-exec
      '';
in
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-model-picker";
  dir = ./.;
  qtModules = [ pkgs.qt6.qtwebsockets ];
  # The daemon requires the Landlock launcher; the passthrough stub stands in
  # (driver.py inherits this via os.environ.copy() into the daemon's env).
  env = {
    SPACES_SESSIOND_LANDLOCK_EXEC = "${landlockExecStub}/bin/pi-landlock-exec";
  };
  extraArgs = [
    (pkgs.lib.getExe daemon)
    "${harness}/mock-llm.py"
    "${stub}/bin/systemd-run"
  ];
  platforms = [ "x86_64-linux" ];
}
