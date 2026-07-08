# Model-directive launch contract test.
#
# Proves backend.launchBackground(prompt, {model}) runs the turn on the
# REQUESTED model, not the executor's default. The session lives on a REAL
# pi-sessiond (bun, embedding pi via its SDK): the panel's create_session
# carries the launched model, and the prompt is gated behind the daemon's
# set_model response (the daemon echoes the request id, so the panel's
# awaited _request resolves before send). The mock LLM serves a multi-model
# list and logs which model every /v1/chat/completions request used; the
# daemon's default is deliberately a different model, so a logged request
# carrying the launched model is a sharp guard against the turn falling
# back to the default.
#
# Reuses the pi-session-quick-launch mock LLM + notify-send stub so the
# launch harness stays single-sourced; the daemon's per-command bash
# confinement wrapper is a passthrough stub (no bash tool commands here).
# No VM, no compositor. ~10-30s.
{ pkgs, inputs, ... }:
let
  daemon = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond;
  harness = ../pi-session-quick-launch;
  # Passthrough launcher stubs (no systemd / no kernel Landlock in the build
  # sandbox); real Landlock enforcement is checks/pi-sessiond-landlock.
  stubs = import ../pi-sessiond-sidechannel/launcher-stubs.nix { inherit pkgs; };
  # The per-session child agent dir no longer inherits the daemon's shared
  # provider auth/models, so the child registers `local` itself via the same
  # llama-swap-discover extension production loads (from LLAMA_SWAP_BASE_URL).
  llamaSwapDiscover =
    inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-chat-extensions.extensions."llama-swap-discover";
in
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-quick-launch-model-directive";
  dir = ./.;
  qtModules = [ pkgs.qt6.qtwebsockets ];
  env = {
    # The daemon requires the Landlock launcher; the passthrough stub stands in
    # (driver.py inherits this via os.environ.copy() into the daemon's env).
    SPACES_SESSIOND_LANDLOCK_EXEC = "${stubs.landlockExec}/bin/landlock-exec";
    # The child is spawned by bare name unless told otherwise; point it at the
    # exact pi the daemon re-exports (the launcher execs an absolute path, not a
    # PATH lookup) — same as production, which sets SPACES_SESSIOND_PI_BIN.
    SPACES_SESSIOND_PI_BIN = pkgs.lib.getExe' daemon.pi "pi";
    SPACES_QL_DISCOVER_EXT = "${llamaSwapDiscover}";
  };
  extraArgs = [
    (pkgs.lib.getExe daemon)
    "${harness}/mock-llm.py"
    "${stubs.systemdRun}/bin/systemd-run"
    "${harness}"
  ];
  platforms = [ "x86_64-linux" ];
}
