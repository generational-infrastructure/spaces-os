# Headless check: the chat panel's WebSocket transport (PiExecutor +
# PiSession in WS mode) against a fake pi-sessiond.
#
# Asserts the panel connects + authenticates, creates a session, sends a
# prompt over the §12 envelope, and renders the streamed reply — the cheap
# per-feature counterpart to the full two-VM test. No compositor, pi, LLM, or
# VM. ~5s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-ws";
  dir = ./.;
  qtModules = [ pkgs.qt6.qtwebsockets ];
  python = pkgs.python3.withPackages (ps: [ ps.websockets ]);
}
