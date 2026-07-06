# Host-directive launch contract test.
#
# Proves backend.launchBackground(prompt, {executor}) pins the launched
# session to the named executor and REFUSES an unknown id (rather than
# silently launching on the default). No pi worker, no LLM: the executor
# field is stamped synchronously by newSession, and a remote-pinned
# (url-less, disconnected) executor routes over WS instead of spawning a
# local pi — so the contract is pure data + control-flow. ~5-10s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-quick-launch-host-directive";
  dir = ./.;
  # PiChatBackend instantiates PiExecutor, which imports QtWebSockets — it
  # lives outside quickshell's bundled QML path, so add it explicitly.
  qtModules = [ pkgs.qt6.qtwebsockets ];
}
