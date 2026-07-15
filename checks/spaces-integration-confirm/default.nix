# Contract check for the standalone confirm popup
# (programs/spaces-integration-confirm). Boots the real popup shell.qml and
# asserts it parses SPACES_CONFIRM_REQUEST, surfaces the call per-field
# (argFields), and writes each verdict token (once|session|deny) to
# SPACES_CONFIRM_VERDICT_FILE — the gateway's confirm contract
# (docs/agent-integrations-generic-mcp-design.md §2/§3).
#
# The popup is a Quickshell PanelWindow on the wlr layer-shell Overlay layer.
# quickshell only loads a PanelWindow backend under a real wayland (or xcb)
# platform — QT_QPA_PLATFORM=offscreen has none — and WlrLayershell needs
# wayland specifically. So the driver boots a throwaway headless wlroots
# compositor (sway) under the check's XDG_RUNTIME_DIR and runs quickshell as a
# wayland client of it (software-rendered, no GPU). No gateway, no VM. ~seconds.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "spaces-integration-confirm";
  dir = ./.;
  pluginDir = ../../programs/spaces-integration-confirm;
  # Headless wlroots compositor providing wlr-layer-shell for the PanelWindow.
  extraInputs = [ pkgs.sway-unwrapped ];
  platforms = [ "x86_64-linux" ];
}
