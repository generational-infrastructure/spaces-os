# Launch-bar completion UI contract test.
#
# Drives the real `completer` controller (QuickBarCompletion.qml) through
# headless quickshell and asserts the plan's §4.2 keyboard table, the §4a
# behavioural edges, and the async "candidates not ready yet" path. The
# controller is hosted in a FloatingWindow with a real PiChatBackend whose
# model cache is seeded deterministically — the offscreen platform ships no
# layer-shell, so the real QuickBar PanelWindow can't be realised (same
# reason pi-chat-panel-width hosts Panel in a FloatingWindow).
#
# No pi worker, no LLM: completion is pure UI logic over a seeded cache, so
# the launch path only needs the backend to mint a session entry. ~5-10s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-quick-launch-completion";
  dir = ./.;
  # PiChatBackend instantiates PiExecutor, which imports QtWebSockets — it
  # lives outside quickshell's bundled QML path, so add it explicitly.
  qtModules = [ pkgs.qt6.qtwebsockets ];
}
