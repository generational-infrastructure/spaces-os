# Spaces Agent Sessions — activity.json producer/consumer contract test.
#
# The sessions bar (programs/noctalia-spaces-sessions/Main.qml) consumes
# the activity feed that pi-chat's PiChatBackend._writeActivity publishes
# at ~/.local/state/spaces/pi/activity.json:
#   { version, activeSessionId, sessions: [{ id, name, state }] }
#   state ∈ "working" | "waiting"
# That schema is an implicit contract living in comments; drift breaks
# the bar silently and only the full VM test would catch it. This check
# hosts the consumer's Main.qml FileView service in a headless
# quickshell, writes literal fixture files replicating the producer's
# output, and asserts the resulting model state over the quickshell IPC
# CLI: empty feed, working+waiting mix, active-session highlight,
# unknown-extra-field tolerance, version-bump tolerance (the consumer
# ignores `version`), keep-previous on a torn/partial read, the
# non-array `sessions` guard, and blank-on-removal.
#
# Main.qml imports only QtQuick/Quickshell/Quickshell.Io, so it runs
# standalone with no noctalia modules. No pi-chat, no compositor. ~3-10s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "spaces-activity-contract";
  dir = ./.;
  pluginDir = ../../programs/noctalia-spaces-sessions;
}
