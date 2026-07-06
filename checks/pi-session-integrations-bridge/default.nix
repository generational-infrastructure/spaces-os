# Contract test for IntegrationsBridge.qml — the panel's client for the
# per-user integrations broker (spaces-integrationd).
#
# Mounts the component pointed at a Python fake of the broker socket and
# exercises the provisioning state machine the settings form relies on: list,
# the enable-without-secret guard, set-secret, enable, disable. Real broker
# behaviour is covered by packages/spaces-integrationd; this isolates the
# QML/IPC layer so a regression in either lands at the right blame surface.
#
# No pi, no LLM, no compositor. ~3-5s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-integrations-bridge";
  dir = ./.;
}
