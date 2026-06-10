# Guard against deploying a closure to the wrong host. Adapted from
# srvos common/detect-hostname-change
# (Copyright (c) 2023 Numtide, MIT — see ./LICENSE).
{
  config,
  lib,
  ...
}:
{
  options.spaces.server.detectHostnameChange.enable = lib.mkEnableOption "" // {
    default = true;
    description = "Warn (and require confirmation) if the hostname changes between deploys.";
  };

  config =
    lib.mkIf (config.spaces.server.detectHostnameChange.enable && config.networking.hostName != "")
      {
        system.preSwitchChecks.detectHostnameChange = ''
          detectHostnameChange() {
            local actual
            actual=$(< /proc/sys/kernel/hostname)

            # Ignore during install (nixos-images installer hostname).
            if [[ ! -e /run/booted-system || "$actual" == "nixos-installer" ]]; then
              return
            fi

            desired=${config.networking.hostName}

            if [[ "$actual" = "$desired" ]]; then
              return
            fi

            # Escape hatch for automation.
            if [[ "''${EXPECTED_HOSTNAME:-}" = "$desired" ]]; then
              return
            fi

            log() {
              echo "$*" >&2
            }

            log "WARNING: machine hostname change detected from '$actual' to '$desired'"
            log
            log "Are you deploying on the right host?"
            log
            log "Type YES to continue:"
            read -r reply
            if [[ $reply != YES ]]; then
              echo "aborting"
              exit 1
            fi
          }
          detectHostnameChange
        '';
      };
}
