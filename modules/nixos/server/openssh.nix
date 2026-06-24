# Hardened OpenSSH defaults. Adapted from srvos common/openssh
# (Copyright (c) 2023 Numtide, MIT — see ./LICENSE).
{ config, lib, ... }:
{
  # SSH is the only way onto a headless box, so it's always on.
  services.openssh = {
    enable = true;

    settings.X11Forwarding = false;
    settings.KbdInteractiveAuthentication = false;
    # Keys only — no passwords over SSH.
    settings.PasswordAuthentication = false;
    settings.UseDns = false;
    # Unbind stale gnupg sockets if they exist.
    settings.StreamLocalBindUnlink = true;

    # Only honour system-level authorized_keys to avoid per-user
    # injections — except when git-forge software relies on per-user
    # keys for push access.
    authorizedKeysFiles = lib.mkIf (
      !config.services.gitea.enable
      && !config.services.gitlab.enable
      && !config.services.gitolite.enable
      && !config.services.gerrit.enable
      && !config.services.forgejo.enable
    ) (lib.mkForce [ "/etc/ssh/authorized_keys.d/%u" ]);
  };

  # Passwordless sudo for wheel — keys-only login means a password
  # prompt buys nothing here.
  security.sudo.wheelNeedsPassword = false;
}
