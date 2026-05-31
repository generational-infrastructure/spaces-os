# Vanilla noctalia-shell bar as a graphical-session user service,
# plus a purge that cleans up leftover state from the prior
# patched-build / spaces-plugin era.
{ pkgs, ... }:
let
  # Removes leftover spaces-owned plugin state on every nixos-rebuild
  # / boot activation: the patched-build `plugins-autoload/` dir, any
  # symlink under `plugins/` (spaces materialised plugins as symlinks,
  # marketplace installs are real dirs), and matching `plugins.json`
  # entries (by unlinked id, by autoload:true flag, or by historical
  # spaces id for hosts where the symlink was already gone).
  purgeStalePlugins = pkgs.writeShellApplication {
    name = "noctalia-purge-stale-plugins";
    runtimeInputs = [
      pkgs.jq
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      cfg="''${XDG_CONFIG_HOME:-$HOME/.config}/noctalia"
      [ -d "$cfg" ] || exit 0

      rm -rf -- "$cfg/plugins-autoload"

      declare -a stale_ids=()
      if [ -d "$cfg/plugins" ]; then
        while IFS= read -r -d "" path; do
          stale_ids+=("$(basename "$path")")
          rm -f -- "$path"
        done < <(find "$cfg/plugins" -mindepth 1 -maxdepth 1 -type l -print0)
      fi

      states="$cfg/plugins.json"
      [ -f "$states" ] || exit 0

      ids_json="[]"
      if [ "''${#stale_ids[@]}" -gt 0 ]; then
        ids_json=$(printf "%s\n" "''${stale_ids[@]}" | jq -R . | jq -s .)
      fi

      tmp=$(mktemp -- "$cfg/.plugins.XXXXXX.json")
      if jq --argjson stale "$ids_json" '
        ["pi-chat", "opencrow-chat", "opencrow-skill-config"] as $legacy |
        if has("states") then
          .states |= with_entries(select(
            ((.value.autoload // false) != true)
            and (.key as $k | $legacy | index($k) | not)
            and (.key as $k | $stale  | index($k) | not)
          ))
        else . end
      ' "$states" >"$tmp"; then
        mv -- "$tmp" "$states"
      else
        rm -f -- "$tmp"
      fi
    '';
  };
in
{
  config = {
    environment.systemPackages = [
      pkgs.noctalia-shell
      pkgs.libnotify
      # Noctalia widgets shell out to wl-{copy,paste} and xdg-open by
      # bare name; ship the binaries on the system PATH.
      pkgs.wl-clipboard
      pkgs.xdg-utils
    ];

    # noctalia's Battery widget reads UPower over D-Bus.
    services.upower.enable = true;

    # Activation runs the purge on every rebuild and boot — no need
    # to wait for the noctalia-shell service to restart.
    system.userActivationScripts.noctaliaPurgeStalePlugins = ''
      ${purgeStalePlugins}/bin/noctalia-purge-stale-plugins
    '';

    systemd.user.services.noctalia-shell = {
      description = "Noctalia Wayland desktop shell";
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      restartTriggers = [ pkgs.noctalia-shell ];
      serviceConfig = {
        ExecStart = "${pkgs.noctalia-shell}/bin/noctalia-shell";
        Restart = "on-failure";
        Slice = "session.slice";
        # Noctalia spawns helpers (`sh`, `wl-paste`, `voxtype`, …) by
        # bare name; the default user PATH only has /run/wrappers/bin.
        Environment = "PATH=/run/wrappers/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin";
      };
    };
  };
}
