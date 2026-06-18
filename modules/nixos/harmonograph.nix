# Default Spaces session background: pinpox' wl-harmonograph, a
# wlr-layer-shell program that animates a damped-pendulum (Lissajous-
# style) harmonograph figure across every output.
#
# niri ships no default wallpaper renderer of its own, so the desktop
# would otherwise come up to a blank/garbage background. This wires
# wl-harmonograph as a graphical-session user service — the same shape
# noctalia-shell (modules/nixos/noctalia.nix) and voxtype
# (modules/nixos/voxtype.nix) use: partOf/after/wantedBy
# graphical-session.target, so it starts once niri's session is up and
# dies with it.
#
# Default-on but overridable via services.spaces.background.enable. The
# colour knobs map onto wl-harmonograph's two env vars (HARMONOGRAPH_FG,
# HARMONOGRAPH_BG); they are the hook a future dark/light theme switch
# would flip in lockstep with noctalia + pi-chat (see
# docs/session-theme-switching.md). Defaults are gruvbox-dark.
#
# The VM OCR path disables this in modules/nixos/test-support so its
# swaybg "SPACES_TEST_OK" wallpaper wins the background layer instead of
# racing two layer-shell renderers.
{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.spaces.background;
in
{
  options.services.spaces.background = {
    enable = lib.mkEnableOption "the wl-harmonograph animated session background" // {
      default = true;
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.wl-harmonograph;
      defaultText = lib.literalExpression "inputs.self.packages.\${system}.wl-harmonograph";
      description = ''
        The wl-harmonograph package to run as the background renderer.
        Defaults to the build under packages/wl-harmonograph (sourced from
        the pinned wl-harmonograph flake input).
      '';
    };

    foreground = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "#fb4934"
        "#b8bb26"
        "#fabd2f"
        "#83a598"
        "#d3869b"
        "#8ec07c"
        "#fe8019"
      ];
      description = ''
        Foreground curve colours (hex). wl-harmonograph cycles through
        the list, one colour per harmonograph figure. Passed through
        the HARMONOGRAPH_FG environment variable. Defaults to the
        gruvbox-dark bright accents — flip these together with
        `background` to follow a light theme.
      '';
    };

    background = lib.mkOption {
      type = lib.types.str;
      default = "#1d2021";
      description = ''
        Background colour (hex), passed through HARMONOGRAPH_BG.
        Defaults to gruvbox-dark hard background.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.user.services.wl-harmonograph = {
      description = "Animated harmonograph session background";
      documentation = [ "https://github.com/pinpox/wl-harmonograph" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      environment = {
        HARMONOGRAPH_FG = lib.concatStringsSep "," cfg.foreground;
        HARMONOGRAPH_BG = cfg.background;
      };
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/wl-harmonograph";
        Restart = "on-failure";
        Slice = "session.slice";
      };
    };
  };
}
