# Attach-image contract test for the chat plugin, end-to-end over WS.
#
# PiSession has no local pi-spawn path; images travel panel -> WS `prompt`
# command -> pi-sessiond supervisor -> the per-session `pi --mode rpc` child
# -> LLM. This check runs the real PiChatBackend (headless quickshell, executor
# injected via $SPACES_PI_CHAT_EXECUTORS with a tokenPath) against the REAL
# pi-sessiond (bun supervisor) driving the REAL pi child, backed by a recording
# mock LLM, drives `sendFile(<tiny png>)` through quickshell's IPC, and asserts:
#
#   - a local "from: me" bubble carrying the image path appears immediately
#     (the regression that made the paperclip button silently drop
#     attachments); and
#   - the recorded /v1/chat/completions request body contains the PNG's exact
#     base64 payload — the panel-encoded image really reached the model.
#
# Because the assertion is on the exact bytes the runtime posts to the LLM,
# this drives the REAL pi (daemon.pi via SPACES_SESSIOND_PI_BIN), not a stub.
# The supervisor no longer embeds pi: each session is a `pi --mode rpc` child
# that does its own provider discovery. The child's settings.json (staged via
# SPACES_SESSIOND_PI_SETTINGS) lists llama-swap-discover, which registers the
# `local` provider from LLAMA_SWAP_BASE_URL (pointed at the recording mock LLM)
# so `mock-model` resolves in the child.
#
# Runs as a normal sandbox build via `pkgs.runCommand` (loopback only).
{ pkgs, inputs, ... }:
let
  daemon = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond;
  # The supervisor spawns this exact pi build per session — the same build its
  # own SDK import resolves against (no child/supervisor skew). Exposed as the
  # daemon package's `pi` passthru.
  piBin = pkgs.lib.getExe' daemon.pi "pi";
  # The child registers the `local` provider itself via llama-swap-discover,
  # loaded from its settings.json (the supervisor no longer embeds pi, so it
  # does no discovery for the child). The pi-chat-extensions package exposes it
  # as a stable-named store file, so the settings.json entry is a clean path.
  llamaSwapDiscover =
    inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-chat-extensions.extensions."llama-swap-discover";
  # Passthrough launcher stubs (no systemd / no kernel Landlock in the build
  # sandbox); real Landlock enforcement is checks/pi-sessiond-landlock.
  stubs = import ../pi-sessiond-sidechannel/launcher-stubs.nix { inherit pkgs; };
in
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-attach-image";
  dir = ./.;
  qtModules = [ pkgs.qt6.qtwebsockets ];
  # The panel-side image reader shells out to `file -b --mime-type` and
  # `base64 -w0` — keep `file` on PATH (coreutils comes with the harness).
  extraInputs = [ pkgs.file ];
  # driver.py inherits this via os.environ.copy() into the daemon's env.
  env = {
    SPACES_SESSIOND_LANDLOCK_EXEC = "${stubs.landlockExec}/bin/landlock-exec";
  };
  extraArgs = [
    (pkgs.lib.getExe daemon)
    piBin
    llamaSwapDiscover
    "${stubs.systemdRun}/bin/systemd-run"
  ];
  platforms = [ "x86_64-linux" ];
}
