# Test/debug support module for distro VMs.
#
# Bundles everything needed to verify a distro install runs correctly
# without test-instrumentation:
#
#   - Serial console (ttyS0) for boot/journal output, so external
#     QEMU monitors can read systemd state without a backdoor shell.
#   - Patched niri that allows software EGL rendering, so VMs without
#     GPU passthrough can actually display the compositor (upstream
#     niri rejects llvmpipe by default).
#
# Imported by `installer-target` (the test-target host) and by manual
# `nix build .#test-vm`-style debug VMs.  Production hosts (real
# hardware installs through Calamares' main.py) do NOT import this.
{ lib, pkgs, ... }:
{
  # ── Serial console for headless verification ────────────────────
  # console=ttyS0 forwards kernel + systemd messages to the QEMU
  # serial port, which the test framework or external QEMU can tee
  # to a log file.  console=tty0 is kept so VGA still shows boot.
  boot.kernelParams = [
    "console=tty0"
    "console=ttyS0,115200n8" # LAST = system console → ForwardToConsole goes here
  ];
  # Disable the agetty on ttyS0 (we use it for journal output, not
  # interactive login).
  systemd.services."serial-getty@ttyS0".enable = false;
  # Forward systemd journal to console so userspace boot progress is
  # visible on serial.
  services.journald.extraConfig = ''
    ForwardToConsole=yes
    MaxLevelConsole=info
  '';

  # ── Software EGL rendering for niri in QEMU ─────────────────────
  # Upstream niri rejects software EGL (llvmpipe) renderers — they
  # have dmabuf-import bugs on real hardware.  Patch gates the check
  # behind NIRI_ALLOW_SOFTWARE_RENDERING=1 so test VMs can render
  # without GPU passthrough.  No-op on real hardware (real GPU EGL
  # devices aren't flagged as software).
  programs.niri.package = pkgs.niri.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ../../../patches/niri-allow-software-rendering.patch
    ];
  });
  systemd.user.services.niri.environment.NIRI_ALLOW_SOFTWARE_RENDERING = "1";

  # ── VM-friendly modifier key ────────────────────────────────────
  # Guest's Super grab fights with the host compositor (which
  # captures Super for its own keybinds). Use Alt instead so VM-
  # based tests can drive niri keybinds via virtio keyboard input.
  services.distro.niri.modKey = "Alt";

  # ── Test wallpaper for OCR detection ────────────────────────────
  # The compositor starts with no default wallpaper renderer.  Spawn
  # swaybg with a pre-rendered wallpaper tiled with "DISTRO_TEST_OK"
  # so VM tests can detect via OCR that niri actually drew something
  # to its outputs (proves the compositor is alive end-to-end, not
  # just that niri.service started).
  environment.systemPackages = [ pkgs.swaybg ];
  systemd.user.services.test-wallpaper = {
    description = "Test wallpaper for OCR-based VM verification";
    wantedBy = [ "niri.service" ];
    after = [ "niri.service" ];
    bindsTo = [ "niri.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.swaybg}/bin/swaybg -i ${
        pkgs.callPackage ./test-wallpaper { }
      }/wallpaper.png -m fill";
      Restart = "on-failure";
    };
  };

  # ── Skip noctalia setup wizard + telemetry wizard ───────────────
  # noctalia gates the user experience behind two first-launch popups
  # that cover the screen and can't be dismissed via keyboard, blocking
  # OCR of the wallpaper:
  #   1. Setup wizard: shown when settings.json is missing
  #      (Settings.isFreshInstall = true).  Pre-seed settings.json so
  #      noctalia treats this as a returning user.
  #   2. "Privacy Update" telemetry wizard: shown when shell-state.json's
  #      changelogLastSeenVersion < telemetryIntroVersion (v4.0.2).
  #      Pre-seed shell-state.json with a far-future version.
  #
  # Also disable noctalia's own wallpaper management.  Its Background.qml
  # renders a layer-shell surface that covers swaybg even when no wallpaper
  # image is configured (Background draws a fallback owl logo on a black
  # surface).  swaybg's DISTRO_TEST_OK tile pattern is what we OCR; it must
  # be the visible bottom layer.
  systemd.user.tmpfiles.rules = [
    "C %h/.config/noctalia/settings.json - - - - ${
      pkgs.writeText "noctalia-settings.json" (
        builtins.toJSON {
          settingsVersion = 0;
          wallpaper = {
            enabled = false;
          };
        }
      )
    }"
    "C %h/.cache/noctalia/shell-state.json - - - - ${
      pkgs.writeText "noctalia-shell-state.json" (
        builtins.toJSON {
          changelogState = {
            lastSeenVersion = "v99.99.99";
          };
        }
      )
    }"
  ];
}
