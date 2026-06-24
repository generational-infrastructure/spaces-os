# sudo hardening. Adapted from srvos common/sudo
# (Copyright (c) 2023 Numtide, MIT — see ./LICENSE).
{ config, ... }:
{
  # Restrict the sudo binary to the wheel group so non-wheel users
  # can't exploit sudo vulnerabilities (e.g. CVE-2021-3156).
  security.sudo.execWheelOnly = true;

  # Don't lecture; less mutable state.
  security.sudo.extraConfig = ''
    Defaults lecture = never
  '';

  # execWheelOnly silently breaks rules targeting other users/groups,
  # so assert the rules only mention root/wheel.
  assertions =
    let
      validUsers = users: users == [ ] || users == [ "root" ];
      validGroups = groups: groups == [ ] || groups == [ "wheel" ];
      validUserGroups = builtins.all (
        r: validUsers (r.users or [ ]) && validGroups (r.groups or [ ])
      ) config.security.sudo.extraRules;
    in
    [
      {
        assertion = config.security.sudo.execWheelOnly -> validUserGroups;
        message = "Some definitions in `security.sudo.extraRules` refer to users other than 'root' or groups other than 'wheel'. Disable `config.security.sudo.execWheelOnly`, or adjust the rules.";
      }
    ];
}
