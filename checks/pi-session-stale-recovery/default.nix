# Stale daemon-session recovery contract test.
#
# sessions.json points at a daemonSessionId the daemon does not know
# (state wiped / deleted elsewhere). The attach bounces with a
# correlated "no such session"; the panel session must drop the stale
# mapping, mint a fresh daemon session, populate models, and persist
# the new mapping — instead of wedging attached-but-dead with every
# command bouncing (the production "panel shows no models" wedge).
# Also pins re-stamping the legacy executor:"" pin with the default
# executor id once the inventory loads.
#
# Real PiChatBackend (headless quickshell) against a real pi-sessiond
# with the shared mock LLM. No VM, no compositor. ~10-30s.
{ pkgs, inputs, ... }:
let
  daemon = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond;
  harness = ../pi-session-quick-launch;
  # Passthrough launcher stubs (no systemd / no kernel Landlock in the build
  # sandbox); real Landlock enforcement is checks/pi-sessiond-landlock.
  stubs = import ../pi-sessiond-sidechannel/launcher-stubs.nix { inherit pkgs; };
in
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-stale-recovery";
  dir = ./.;
  qtModules = [ pkgs.qt6.qtwebsockets ];
  # The daemon requires the Landlock launcher; the passthrough stub stands in
  # (driver.py inherits this via os.environ.copy() into the daemon's env).
  env = {
    SPACES_SESSIOND_LANDLOCK_EXEC = "${stubs.landlockExec}/bin/landlock-exec";
  };
  extraArgs = [
    (pkgs.lib.getExe daemon)
    "${harness}/mock-llm.py"
    "${stubs.systemdRun}/bin/systemd-run"
  ];
  platforms = [ "x86_64-linux" ];
}
