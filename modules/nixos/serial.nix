# Serial console on the first serial port, in addition to the graphical one.
# This is the emergency-access path on headless/cloud hosts (Hetzner SOL, IPMI,
# BMC serial redirection). Harmless on machines without a serial port.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Match the terminal size to the serial window on login (serial ttys don't get
  # SIGWINCH). No-op on anything that isn't a serial tty.
  resize = pkgs.writeShellScriptBin "resize" ''
    export PATH=${pkgs.coreutils}/bin
    if [ ! -t 0 ]; then
      exit 0
    fi
    TTY="$(tty)"
    if [[ "$TTY" != /dev/ttyS* ]] && [[ "$TTY" != /dev/ttyAMA* ]] && [[ "$TTY" != /dev/ttySIF* ]]; then
      exit 0
    fi
    old=$(stty -g)
    stty raw -echo min 0 time 5
    printf '\0337\033[r\033[999;999H\033[6n\0338' > /dev/tty
    IFS='[;R' read -r _ rows cols _ < /dev/tty
    stty "$old"
    stty cols "$cols" rows "$rows"
  '';
in
{
  options.spaces.boot.consoles = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [
      "ttyS0,115200"
    ]
    ++ (lib.optional pkgs.stdenv.hostPlatform.isAarch "ttyAMA0,115200")
    ++ (lib.optional pkgs.stdenv.hostPlatform.isRiscV64 "ttySIF0,115200")
    ++ [ "tty0" ];
    example = [ "ttyS2,115200" ];
    description = ''
      Kernel `console=` devices. The default mirrors kernel output to both the
      graphical console (tty0) and the first serial port (ttyS0 @ 115200) so a
      cloud/BMC serial redirection can reach the boot log and an emergency shell.
      The last entry becomes /dev/console.
    '';
  };

  config = {
    boot.kernelParams = map (c: "console=${c}") config.spaces.boot.consoles;
    environment.loginShellInit = "${resize}/bin/resize";
    environment.systemPackages = [ resize ];
    systemd.services."serial-getty@".environment.TERM = "xterm-256color";
    boot.loader.grub.extraConfig = ''
      serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
      terminal_input --append serial
      terminal_output --append serial
    '';
  };
}
