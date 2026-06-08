# Welcome-page screenshot harness.
#
# A trimmed cousin of installer-gui-end-to-end.nix: it boots the same GNOME +
# Calamares live environment (with our spaces overlay) but stops at the
# Calamares welcome page and saves screenshots instead of driving the full
# install. Use it to eyeball the welcome-page styling (Geist font, hero image,
# light sidebar, heading/body) against ./mockup-welcome.png.
#
#   nix build -L .#debug.x86_64-linux.installer-welcome-screenshot --keep-failed
#   # screenshots land in the build's $out: 01-welcome*.png
#
# Requires /dev/kvm and ~8 GiB RAM. Unlike the e2e test it needs no network and
# does no nix-build/install, so it is comparatively quick.
{
  pkgs,
  inputs,
  ...
}:
pkgs.testers.runNixOSTest {
  name = "installer-welcome-screenshot";
  node.specialArgs = { inherit inputs; };
  node.pkgsReadOnly = false;
  enableOCR = true;

  nodes.installer =
    { lib, ... }:
    {
      imports = [
        "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-calamares-gnome.nix"
      ];

      # Shadow upstream calamares-nixos-extensions with our fork (mkForce to
      # beat the installation-device profile's own overlay).
      nixpkgs.overlays = lib.mkForce [
        (final: prev: {
          calamares-nixos-extensions = final.callPackage ../packages/calamares-spaces-extensions {
            base = prev.calamares-nixos-extensions;
          };
        })
      ];

      # The branding stylesheet.qss selects Geist; make it resolvable in the
      # live env (mirrors modules/nixos/installer-iso.nix). Without this the
      # screenshot would fall back to the default sans and misrepresent the
      # styling.
      fonts.packages = [ pkgs.geist-font ];

      virtualisation = {
        memorySize = 8192;
        cores = 4;
        # The welcome page only renders the hero image (#welcomeLogo) once the
        # requirements check PASSES (ResultsListWidget::requirementsComplete).
        # welcome.conf requires >=10 GiB storage + 3 GiB RAM, so give the VM a
        # spare 16 GiB disk (/dev/vdb) to install onto -- without it the page
        # shows the "not enough drive space" failure list instead of the hero.
        emptyDiskImages = [ 16384 ];
        resolution = {
          x = 1280;
          y = 800;
        };
      };
    };

  testScript = ''
    import re
    import time

    installer.start()
    installer.wait_for_unit("display-manager.service", timeout=120)

    # Wait for the GNOME session, then for Calamares to spawn.
    installer.wait_until_succeeds(
        "systemctl --user -M nixos@.host is-active graphical-session.target 2>/dev/null"
        " || pgrep -u nixos gnome-shell",
        timeout=180,
    )
    installer.wait_until_succeeds("pgrep -f calamares", timeout=180)

    # The compositor takes a while to actually paint the Calamares window onto
    # the framebuffer (before that the QEMU display still shows the boot
    # console). Poll OCR for welcome-page-specific text -- NOT generic words
    # like "installer" that also appear in console output -- dismissing the
    # GNOME Activities overview each round. Welcome page shows the language
    # combo ("American English"), the URL buttons ("Release notes") and the
    # heading ("Welcome to the Spaces OS installer").
    welcome_re = re.compile(
        r"(American English|Release notes|Known issues|Every Space|foundation)"
    )
    found = False
    for attempt in range(60):  # up to ~120s
        installer.send_key("esc")
        text = installer.get_screen_text()
        print(f"welcome OCR {attempt}: {text[:200]}")
        if welcome_re.search(text):
            found = True
            break
        installer.sleep(2)

    # Once the welcome page is up, the requirements check still runs for a few
    # seconds (spinner). Wait for it to settle into the satisfied state -- the
    # body line becomes the Spaces OS copy ("...create a digital environment
    # ...under your control.") and the hero image appears -- before capturing.
    # Fall back after a bounded wait so we still get a screenshot even if OCR
    # misses the phrase.
    settled_re = re.compile(r"(digital environment|under your control|truly yours)")
    for _ in range(20):  # up to ~40s
        text = installer.get_screen_text()
        if settled_re.search(text):
            break
        installer.sleep(2)

    if found:
        installer.sleep(2)
        # The centered ~800x520 window is the closest framing to the mockup
        # (title bar + sidebar + content), so capture it before maximizing.
        installer.screenshot("01-welcome")

    # Also capture a maximized view so the hero image renders at full size.
    def mouse_click(px, py):
        ax = int(px * 32767 / 1280)
        ay = int(py * 32767 / 800)
        installer.qmp_client.send("input-send-event", {"events": [
            {"type": "abs", "data": {"axis": "x", "value": ax}},
            {"type": "abs", "data": {"axis": "y", "value": ay}},
            {"type": "btn", "data": {"button": "left", "down": True}},
        ]})
        time.sleep(0.1)
        installer.qmp_client.send("input-send-event", {"events": [
            {"type": "abs", "data": {"axis": "x", "value": ax}},
            {"type": "abs", "data": {"axis": "y", "value": ay}},
            {"type": "btn", "data": {"button": "left", "down": False}},
        ]})

    # Maximise the window so the hero renders at full size. Click the title bar
    # to focus the window (NOT the content -- on a tall window a content click
    # lands on the language combo, which opens it and lets the subsequent key
    # change the locale, dropping our English-only branding copy), then drive
    # GNOME's Super+Up. The welcome window must stay within the 800px screen
    # height for the title bar to sit where this click expects it; the
    # #welcomeLogo min-height in the branding QSS is kept small enough for that.
    mouse_click(640, 173)
    time.sleep(1)
    installer.send_key("meta_l-up")
    installer.sleep(3)
    installer.screenshot("02-welcome-maximized")

    assert found, "Calamares welcome page not detected"
  '';
}
