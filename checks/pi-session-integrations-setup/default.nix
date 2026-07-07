# Contract test for the panel's integration device-setup flow
# (SettingsWindow + IntegrationsBridge over spaces-integrationd's setup
# channel).
#
# Mounts the real SettingsWindow against a Python fake broker that streams
# the setup op's NDJSON events (qr | message | done | error), and asserts
# the setup-button visibility gate, the streamed QR image, the done
# auto-close + re-list, and the error path. Real broker streaming is covered
# by packages/spaces-integrationd; this isolates the QML/IPC layer so a
# regression lands at the right blame surface.
#
# No pi, no LLM, no compositor. ~3-5s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-integrations-setup";
  dir = ./.;
}
