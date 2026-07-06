# Headless check: the panel's loopback-executor wiring (pi-chat.json
# `localExecutor` -> PiChatBackend.executors entry -> WS hello with the
# per-login runtime token).
#
# Asserts the backend, pointed (via $SPACES_PI_CHAT_CONFIG) at a fixture
# config carrying `localExecutor`, materializes a "host" executor entry
# whose tokenPath is $XDG_RUNTIME_DIR/pi-sessiond/token, then
# authenticates against a fake pi-sessiond with the token-file content
# (hello -> welcome) — and, without `localExecutor`, keeps the executors
# list empty (the transient no-executor state; spawns defer until an
# executor is configured). No compositor, pi, LLM, or VM. ~10s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-local-executor";
  dir = ./.;
  qtModules = [ pkgs.qt6.qtwebsockets ];
  python = pkgs.python3.withPackages (ps: [ ps.websockets ]);
  # hello/welcome (+ token check) is all this check needs from a daemon;
  # reuse the WS transport check's fake instead of forking it.
  extraArgs = [ "${../pi-session-ws/fake-daemon.py}" ];
}
