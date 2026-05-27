# End-to-end VM test for the installer-target host shape.
#
# Boots a system whose configuration mirrors what the patched
# Calamares main.py emits at install time (Calamares-shape user with
# extraGroups = [ wheel networkmanager ], greetd autologin via
# distro module's default_session, no DE imports beyond the distro
# module) and verifies the full user-session path:
#   greetd → niri → wayland socket → pi-chat.service
#   → compositor actually paints frames (OCR of test wallpaper).
#
# Closes the gap left by `installer-loadmodule`: that test stubs
# both `nix-build` and `nixos-install`, so any runtime issue in the
# installed system (missing service, broken user-tmpfiles, niri
# startup failure, dead compositor) is invisible to it.
{ pkgs, inputs, ... }:

pkgs.testers.runNixOSTest {
  name = "installer-target-session";
  node.specialArgs = { inherit inputs; };
  enableOCR = true;

  nodes.target =
    { lib, ... }:
    {
      imports = [
        inputs.self.nixosModules.distro
        ../hosts/installer-target/configuration.nix
        ../modules/nixos/test-support
      ];

      # The host pins a real disk + bootloader; the test framework
      # provides its own. Force them off so we don't try to run
      # systemd-boot install in a VM with no ESP.
      fileSystems = lib.mkForce { };
      boot.loader.systemd-boot.enable = lib.mkForce false;

      virtualisation = {
        memorySize = 4096;
        cores = 4;
        writableStore = true;
      };
    };

  testScript =
    { nodes, ... }:
    let
      uid = toString nodes.target.users.users.installed.uid;
    in
    ''
      target.wait_for_unit("multi-user.target")

      with subtest("greetd autostarts the niri session"):
          target.wait_for_unit("greetd.service")
          target.wait_until_succeeds(
              "systemctl is-active user@${uid}.service",
              timeout=30,
          )

      with subtest("niri.service starts under the user manager"):
          target.wait_until_succeeds(
              "systemctl --user --machine=installed@.host is-active niri.service",
              timeout=30,
          )

      with subtest("niri exposes its Wayland socket"):
          target.wait_for_file("/run/user/${uid}/wayland-1", timeout=30)

      with subtest("pi-chat.service is running"):
          target.wait_until_succeeds(
              "systemctl --user --machine=installed@.host is-active pi-chat.service",
              timeout=30,
          )
          target.wait_until_succeeds(
              "test -d /run/user/${uid}/quickshell",
              timeout=30,
          )

      with subtest("pi-chat shell config is materialized"):
          # distro-pi-chat-sync.service copies the shell from /nix/store
          # into ~/.config/quickshell/pi-chat with fresh mtimes (Qt
          # qmlcache invalidation). Assert the materialized copy exists
          # and has the entry point.
          target.wait_until_succeeds(
              "test -f /home/installed/.config/quickshell/pi-chat/shell.qml",
              timeout=30,
          )

      with subtest("compositor renders the test wallpaper"):
          # test-support.nix configures swaybg with a wallpaper containing
          # tiled "DISTRO_TEST_OK" text. OCR detection proves the
          # compositor is alive and rendering to its outputs — systemd
          # unit state alone can't catch a wedged compositor.
          # Dismiss niri's "Important Hotkeys" overlay shown on first launch.
          target.send_key("esc")
          target.sleep(2)
          import re
          found = False
          for attempt in range(5):  # up to 15s
              target.sleep(3)
              target.screenshot(f"frame-{attempt:02d}")
              text = target.get_screen_text()
              print(f"OCR attempt {attempt}: {text[:200]}")
              if re.search(r"DISTRO[_\s]+TEST[_\s]+OK", text):
                  print(f"Wallpaper marker detected on attempt {attempt}")
                  found = True
                  break

          assert found, (
              "'DISTRO_TEST_OK' wallpaper text not detected in OCR. "
              "niri may not be rendering, or swaybg failed to start. "
              "Check frame-*.png screenshots in test output."
          )
    '';
}
