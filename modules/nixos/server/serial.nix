# Serial console support. Adapted from srvos common/serial
# (Copyright (c) 2023 Numtide, MIT — see ./LICENSE).
#
# Bare-metal servers are often reached over IPMI Serial-over-LAN or a
# GPIO serial terminal; this wires kernel, getty and grub for that.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Resize the terminal to match the serial client's window.
  # Based on https://unix.stackexchange.com/questions/16578/
  resize = pkgs.writeShellScriptBin "resize" ''
    export PATH=${pkgs.coreutils}/bin
    if [ ! -t 0 ]; then
      # not interactive
      exit 0
    fi
    TTY="$(tty)"
    if [[ "$TTY" != /dev/ttyS* ]] && [[ "$TTY" != /dev/ttyAMA* ]] && [[ "$TTY" != /dev/ttySIF* ]]; then
      # probably not a serial console
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
  options.spaces.server.consoles = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [
      "ttyS0,115200"
    ]
    ++ (lib.optional pkgs.stdenv.hostPlatform.isAarch "ttyAMA0,115200")
    ++ (lib.optional pkgs.stdenv.hostPlatform.isRiscV64 "ttySIF0,115200")
    ++ [ "tty0" ];
    example = [ "ttyS2,115200" ];
    description = ''
      Kernel `console=` devices. The default prints kernel messages to
      the graphical console (VGA/HDMI) and to the first serial port
      (ttyS0) at 115200 baud — handy for IPMI SOL or embedded serial
      terminals. The last device listed is used for /dev/console. See
      <https://www.kernel.org/doc/html/latest/admin-guide/serial-console.html>.
    '';
  };

  config = {
    boot.kernelParams = map (c: "console=${c}") config.spaces.server.consoles;

    # Set terminal size once after login, and ship the helper so it can
    # be re-run when the local window changes.
    environment.loginShellInit = "${resize}/bin/resize";
    environment.systemPackages = [ resize ];

    # Default getty TERM is vt220-ish; we want some colour.
    systemd.services."serial-getty@".environment.TERM = "xterm-256color";

    # Make grub respond on the serial console too.
    boot.loader.grub.extraConfig = ''
      serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
      terminal_input --append serial
      terminal_output --append serial
    '';
  };
}
