# Spaces Voice Indicator — headless reactivity component test.
#
# Hosts the plugin's Main.qml FileView service in a headless quickshell
# and drives it the way voxtype does: by writing the bare state word to
# $XDG_RUNTIME_DIR/voxtype/state (truncate-in-place, mirroring voxtype's
# std::fs::write). Reads voiceState back over the quickshell ipc CLI and
# asserts the reactive lifecycle down→idle→recording→transcribing→
# streaming, the keep-previous rule on an empty read, and onLoadFailed→
# down when the daemon removes the file.
#
# Main.qml imports only QtQuick/Quickshell/Quickshell.Io, so it runs
# standalone with no noctalia modules. No voxtype, no compositor. ~3-10s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "spaces-voice-indicator-state";
  dir = ./.;
  pluginDir = ../../programs/noctalia-voice-indicator;
}
