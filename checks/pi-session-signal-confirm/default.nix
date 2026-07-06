# Contract test for SignalConfirm.qml.
#
# Mounts the QML component pointed at a Python fake of the
# spaces-signal-bridge panel socket and exercises the subscribe /
# snapshot / added / removed / approve / deny state machine. Real
# bridge behaviour is covered by packages/signal-cli/test_bridge.py;
# this isolates the QML/IPC layer so a regression in either lands
# at the right blame surface.
#
# No pi, no LLM, no compositor. ~5-8s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-signal-confirm";
  dir = ./.;
}
