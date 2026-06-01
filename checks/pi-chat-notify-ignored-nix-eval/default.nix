# Cheap nix-eval contract: the quick-launch completion notification
# must not be re-injected into chat by distro-notify-forward.
#
# launchBackground fires `notify-send -a pi-chat … "Agent finished"` on
# completion. distro-notify-forward snoops every D-Bus Notify and
# forwards it into the active chat session — unless the app name is in
# notificationForwarding.ignoredApps. So `pi-chat` MUST be in the
# effective ignore list, or every background agent's own completion
# toast loops straight back into the conversation as a "[Notification]"
# message.
#
# Asserts against the value an unconfigured distro host resolves (the
# distro module auto-enables pi-chat). Pure nix eval. ~3-5s.
{ pkgs, inputs, ... }:
let
  system = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = {
      inherit inputs;
      flake = inputs.self;
    };
    modules = [
      inputs.self.nixosModules.spaces
      {
        nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        boot.loader.grub.enable = false;
        system.stateVersion = "26.05";
        services.pi-chat.notificationForwarding.enable = true;
      }
    ];
  };
  # The forwarder matches app names case-insensitively, so compare
  # lowercased exactly as distro-notify-forward does.
  ignored = map inputs.nixpkgs.lib.toLower system.config.services.pi-chat.notificationForwarding.ignoredApps;
in
pkgs.runCommand "pi-chat-notify-ignored-nix-eval"
  {
    ignoredApps = inputs.nixpkgs.lib.concatStringsSep "\n" ignored;
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }

    printf '%s\n' "$ignoredApps" | grep -qx "pi-chat" \
      || fail "pi-chat is not in the effective notificationForwarding.ignoredApps: [$ignoredApps]"

    touch "$out"
  ''
