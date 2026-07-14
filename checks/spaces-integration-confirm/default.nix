# Contract check for the standalone confirm popup
# (programs/spaces-integration-confirm). Boots the real popup shell.qml headless
# and asserts it parses SPACES_CONFIRM_REQUEST and writes each verdict token
# (once|session|deny) to SPACES_CONFIRM_VERDICT_FILE — the gateway's confirm
# contract (docs/agent-integrations-generic-mcp-design.md §2/§3). No compositor,
# no gateway. ~seconds.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "spaces-integration-confirm";
  dir = ./.;
  pluginDir = ../../programs/spaces-integration-confirm;
}
