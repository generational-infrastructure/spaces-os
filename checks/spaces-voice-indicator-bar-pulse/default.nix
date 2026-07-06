# Spaces Voice Indicator — bar-pulse activation component test.
#
# Hosts two copies of the plugin's Main.qml service in a headless
# quickshell and drives them by writing voxtype's state word, exactly as
# the sibling state test does. Asserts that the whole-bar ambient pulse
# (the second "you are being recorded" cue, separate from the per-widget
# mic recolor) derives purely from the existing voiceState signal:
#
#   - pulseActive is ON for recording/streaming and ONLY then (off for
#     idle / transcribing / down);
#   - barPulse defaults ON (no pluginApi → enabled), so the cue ships
#     without per-host wiring;
#   - barPulse=false suppresses the pulse while leaving voiceState intact,
#     so the opt-out can't desync from the daemon.
#
# Main.qml stays standalone (imports only QtQuick/Quickshell/Quickshell.Io)
# because neither host arms the overlay LazyLoader, so this needs no
# noctalia modules and no compositor. ~3-10s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "spaces-voice-indicator-bar-pulse";
  dir = ./.;
  pluginDir = ../../programs/noctalia-voice-indicator;
}
