# Panel.qml surface-width regression test.
#
# Embeds the real chat Panel inside a 480 px-wide FloatingWindow the
# way shell.qml embeds it inside a 480 px PanelWindow, and asserts
# the Panel does NOT drag the surface wider than the shell asked for.
#
# Guards the bug where Panel.qml's leftover SmartPanel
# `implicitWidth: contentPreferredWidth (1000)` propagated up through
# QQuickWindow's contentItem and made the wayland surface ~1000 px,
# clipping the header buttons and every chat bubble off the right
# edge of the screen.
#
# No pi process, no LLM, no compositor. ~3s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-chat-panel-width";
  dir = ./.;
}
