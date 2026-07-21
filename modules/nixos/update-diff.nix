# Print the package/closure diff against the running system on every
# `nixos-rebuild switch/boot`, so a deploy shows exactly what it changes.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  options.spaces.update-diff = {
    enable = lib.mkEnableOption "showing a package diff when updating" // {
      default = true;
    };
    command = lib.mkOption {
      type = lib.types.singleLineStr;
      default =
        if lib.versionAtLeast (pkgs.dix.version or "0") "1.4.2" then
          "${lib.getExe pkgs.dix} --force-correctness"
        else
          "${pkgs.nvd}/bin/nvd --nix-bin-dir=${config.nix.package}/bin diff";
      defaultText = lib.literalExpression ''"''${lib.getExe pkgs.dix} --force-correctness"'';
      description = "The diff command to run (dix if new enough, else nvd).";
    };
  };

  config = lib.mkIf config.spaces.update-diff.enable {
    system.preSwitchChecks.update-diff = ''
      incoming="''${1-}"
      if [[ -e /run/current-system && -e "''${incoming-}" ]]; then
        echo "--- diff to current-system"
        ${config.spaces.update-diff.command} /run/current-system "''${incoming-}"
        echo "---"
      fi
    '';
  };
}
