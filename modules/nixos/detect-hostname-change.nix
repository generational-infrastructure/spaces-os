# Guard against deploying a config to the wrong host: if the running hostname
# doesn't match the one being switched to, prompt before continuing. Set
# EXPECTED_HOSTNAME to skip the prompt in automation.
{
  config,
  lib,
  ...
}:
{
  options.spaces.detect-hostname-change.enable = lib.mkEnableOption "" // {
    default = true;
    description = "Warn (and prompt) if the hostname changes between deploys.";
  };

  config =
    lib.mkIf (config.spaces.detect-hostname-change.enable && config.networking.hostName != "")
      {
        system.preSwitchChecks.detectHostnameChange = ''
          detectHostnameChange() {
            local actual
            actual=$(< /proc/sys/kernel/hostname)
            if [[ ! -e /run/booted-system || "$actual" == "nixos-installer" ]]; then
              return
            fi
            desired=${config.networking.hostName}
            if [[ "$actual" = "$desired" ]]; then
              return
            fi
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
