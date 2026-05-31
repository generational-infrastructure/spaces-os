# installer-target host configuration — a stand-in for what
# Calamares would write into /etc/nixos on the installed system.
#
# Kept deliberately close to the shape of the patched main.py's
# generated configuration.nix so a regression in either side surfaces
# the same way: same user groups, same greetd default-session user,
# same explicit bootloader, no DE module imports.
#
# Pure config — no module imports. The spaces module + (for tests)
# test-support are wired in by default.nix (blueprint host) or the
# debug session test directly.
_:

{
  networking.hostName = "installer-target";

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  fileSystems."/" = {
    device = "/dev/vda1";
    fsType = "ext4";
  };

  # Mirror the rest of `main.py`'s emitted config blocks. None of
  # these is strictly necessary for niri startup, but pinning them
  # here means a future regression in the network / locale / keymap
  # rendering surfaces in this VM test instead of only at manual
  # ISO-install time.
  networking.networkmanager.enable = true;
  time.timeZone = "Europe/Berlin";
  i18n.defaultLocale = "en_US.UTF-8";
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };
  console.keyMap = "us";

  users.users.installed = {
    isNormalUser = true;
    uid = 1000;
    # No `initialPassword`: Calamares' users module creates the
    # user during install and runs `passwd` inside the chroot to
    # set the password. The generated NixOS configuration doesn't
    # pre-populate a hash. Mirror that here so any regression
    # specific to "user has a password from useradd, not from
    # NixOS activation" surfaces in the test.
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
  };

  # Override spaces's `lib.mkDefault "alice"` greetd autologin user.
  services.greetd.settings.default_session.user = "installed";

  system.stateVersion = "26.05";
}
