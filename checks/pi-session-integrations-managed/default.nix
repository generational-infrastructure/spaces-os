# Contract test for the panel's Nix-managed integration profiles
# (SettingsWindow + IntegrationsBridge rendering the managed-profile fields
# of spaces-integrationd's `list` reply — design doc §10).
#
# Mounts the real SettingsWindow against a Python fake broker whose `list`
# reply carries managed/shadowed profiles and enabledByNix verdicts (§10.5),
# then asserts the read-only managed-profile GUI contract (§10.7): a managed
# profile shows a lock badge + STATIC config rows and its edit/remove
# affordances are absent from the tree (not merely disabled); enabledByNix
# integrations show a static enable label instead of the enable/disable
# toggle; the add-account input stays on multiProfile integrations; and an
# add-profile draft naming a managed profile is blocked. A raw-socket probe
# then verifies the broker's managed-write rejection messages (§10.5) verbatim.
#
# Isolates the QML/IPC layer so a managed-provisioning regression lands at the
# right blame surface; the real broker/stager are covered elsewhere.
#
# No pi, no LLM, no compositor. ~3-5s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-integrations-managed";
  dir = ./.;
}
