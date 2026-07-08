# Proton Mail Bridge backing for the spaces AI agent's Proton integration.
#
# Proton Mail has no public IMAP/SMTP; Proton Mail Bridge is the official daemon
# that logs into Proton, decrypts/encrypts locally, and exposes a standard
# loopback IMAP + SMTP server the generic himalaya/msmtp integration talks to.
#
# In the gRPC-era, Landlock-confined architecture the daemon is NOT a raw unit
# owned here. It rides the Proton integration manifest's CONFINED extraServices
# entry (../spaces-integrations/defaults.nix `proton`), which the
# spaces-integrations materialiser wraps in landlock-exec + the shared hardening
# bouquet, vault-gates (ConditionPathExists), and pulls in via the integration
# socket. Onboarding (a paid-plan Proton login) happens through the panel setup
# helper, which the broker parks the daemon for (setupPark) and which spawns its
# own transient `protonmail-bridge --grpc`.
#
# This module stays THIN. It owns:
#   * the `services.spaces-proton-bridge` option surface;
#   * the env-pinned `protonmail-bridge` wrapper on PATH (ad-hoc / debug CLI;
#     the daemon + setup units resolve the SAME wrapper via ./wrapper.nix);
#   * pre-creating the Bridge state root, so the confined units' Landlock
#     `extraPaths` rw grant on it attaches (Landlock silently drops a grant for
#     a missing path — see ../spaces-integrations/lib.nix).
#
# The wrapper's determinism + XDG pinning + keychain bootstrap live in
# ./wrapper.nix (shared verbatim with the manifest, no config coupling).
#
# Enablement tracks pi-chat (like signal-cli): imported by pi-chat so every
# consumer gets it, and keyed to pi-chat.enable so it stays inert when pi-chat
# is imported-but-disabled.
{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.spaces-proton-bridge;

  # The SAME wrapper the Proton integration manifest builds (../spaces-
  # integrations/defaults.nix imports the identical ./wrapper.nix). Sharing the
  # pure builder keeps the daemon's ExecStart wrapper and the on-PATH ad-hoc
  # wrapper byte-identical.
  wrapper = import ./wrapper.nix {
    inherit pkgs lib;
    inherit (cfg) package;
  };

  stateRel = ".local/state/protonmail-bridge";
in
{
  options.services.spaces-proton-bridge = {
    enable =
      lib.mkEnableOption ''
        Proton Mail Bridge backing for the Proton integration: the env-pinned
        `protonmail-bridge` wrapper on PATH plus its confined state root. The
        daemon itself rides the Proton integration's confined extraService and
        stays inert until the one-time panel setup (needs a paid Proton plan)
        creates the Bridge vault''
      // {
        # Tracks pi-chat: this module is imported only by pi-chat, so every
        # pi-chat consumer gets the Bridge backing for free. Tracking (rather
        # than a flat `true`) keeps it inert when pi-chat is imported but
        # disabled, instead of tripping the assertion below.
        default = config.services.pi-chat.enable;
        defaultText = lib.literalExpression "config.services.pi-chat.enable";
      };

    package = lib.mkPackageOption pkgs "protonmail-bridge" { };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # The Bridge exists to feed the Proton integration MCP server, which
        # pi-chat wires up via spaces-integrations. Without pi-chat the wrapper
        # + state root ship but nothing consumes them. `or false` keeps this a
        # clean assertion when the pi-chat module is not imported at all.
        assertion = config.services.pi-chat.enable or false;
        message = ''
          services.spaces-proton-bridge.enable = true requires services.pi-chat.enable = true.

          Proton Mail Bridge backs the Proton integration (enabled through
          pi-chat). If you want the wrapper without pi-chat, install
          pkgs.protonmail-bridge and manage the daemon yourself.
        '';
      }
    ];

    # `protonmail-bridge` on PATH for ad-hoc / debug CLI use; it is the same
    # env-pinning wrapper the confined daemon + setup units run.
    environment.systemPackages = [ wrapper ];

    # Pre-create the state root (0700) so the confined daemon / setup / MCP
    # units' Landlock `extraPaths` rw grant on it attaches — Landlock skips a
    # missing path, silently dropping the grant. Bridge creates the config/
    # data/ gnupg/ subtree itself (the wrapper `install -d`s GNUPGHOME too).
    systemd.user.tmpfiles.rules = [
      "d %h/${stateRel} 0700 - - -"
    ];
  };
}
