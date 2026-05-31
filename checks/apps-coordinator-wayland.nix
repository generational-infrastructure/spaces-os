# NixOS VM check for the Wayland security-context-v1 half of the
# apps module.
#
# Pairs with `checks/apps-coordinator.nix` (which covers the systemd
# half — manifest, launcher, coordinator protocol, sandbox mount
# layout — without a compositor). This check brings up niri so the
# full path can be exercised:
#
#   coordinator → launcher → systemd-run sandbox →
#   wayland-app-context (creates wp_security_context_v1) →
#   niri (filters restricted protocol globals from registry) →
#   target (sees nothing it could use to escape)
#
# A `probe-wayland` app whose target is wayland-info is spawned
# through the coordinator. wayland-info iterates the Wayland
# registry; its output lands in the user journal. The test asserts
# that NONE of the security-context-gated globals
# (wlr_screencopy, wp_security_context_manager, foreign_toplevel,
#  wlr_data_control, ext_data_control, virtual_keyboard,
#  virtual_pointer, layer_shell, session_lock, input_method)
# reach the sandboxed client, while baseline interfaces like
# wl_compositor still do.
#
# x86_64-linux only: same builder-feature reason as the sibling check.
{ pkgs, inputs, ... }:

if pkgs.stdenv.hostPlatform.system != "x86_64-linux" then
  pkgs.runCommand "apps-coordinator-wayland-x86_64-only" { } "mkdir -p $out"
else
  pkgs.testers.runNixOSTest {
    name = "apps-coordinator-wayland";
    node.specialArgs = { inherit inputs; };
    nodes.machine =
      { config, pkgs, ... }:
      {
        imports = [
          # niri compositor + the supporting services its default
          # config relies on (polkit, gnome-keyring, swaylock PAM).
          inputs.self.nixosModules.niri
          # The module under test.
          inputs.self.nixosModules.apps
          # Patched niri (allows llvmpipe), serial console for
          # debugging, software-rendering env var.
          inputs.self.nixosModules.test-support
        ];

        users.users.test = {
          isNormalUser = true;
          uid = 1000;
          initialPassword = "test";
          extraGroups = [ "wheel" ];
        };

        services.greetd = {
          enable = true;
          settings.default_session = {
            command = "${config.programs.niri.package}/bin/niri-session";
            user = "test";
          };
        };

        services.spaces.apps.probe-wayland = {
          package = pkgs.wayland-utils;
          exec = "${pkgs.wayland-utils}/bin/wayland-info";
          # `wayland` triggers the wayland-app-context wrapper in the
          # launcher; `wm.spawn-named-tasks` is granted so the
          # coordinator activates (otherwise `anyAppNeedsCoordinator`
          # would be false and the test has no way to spawn).
          permissions.granted = [
            "wayland"
            "wm.spawn-named-tasks"
          ];
        };

        # Counterpart that opts out of the security-context wrap.
        # Used to verify `waylandSandbox = false` actually skips the
        # wayland-app-context helper — the sandboxed client should
        # see the restricted protocol globals that probe-wayland
        # cannot. This is the regression test for the voxtype use
        # case (typers need the virtual-keyboard protocol).
        services.spaces.apps.probe-wayland-raw = {
          package = pkgs.wayland-utils;
          exec = "${pkgs.wayland-utils}/bin/wayland-info";
          permissions.granted = [ "wayland" ];
          waylandSandbox = false;
        };

        environment.systemPackages = [ pkgs.socat ];

        # 2GB so the in-VM niri + swaybg + wayland-info pipeline
        # doesn't OOM under heavy software rendering.
        virtualisation = {
          memorySize = 2048;
          cores = 2;
          writableStore = true;
        };
      };

    testScript = ''
      machine.wait_for_unit("multi-user.target")

      with subtest("greetd autostarts the niri session"):
          machine.wait_for_unit("greetd.service")
          machine.wait_until_succeeds(
              "systemctl is-active user@1000.service",
              timeout=60,
          )

      with subtest("niri.service starts under the user manager"):
          machine.wait_until_succeeds(
              "systemctl --user --machine=test@.host is-active niri.service",
              timeout=60,
          )

      with subtest("niri exposes its Wayland socket"):
          machine.wait_for_file("/run/user/1000/wayland-1", timeout=30)

      with subtest("coordinator activates"):
          machine.wait_until_succeeds(
              "systemctl --user --machine=test@.host is-active spaces-app-coordinator.service",
              timeout=30,
          )
          machine.wait_until_succeeds(
              "test -S /run/user/1000/spaces-app-coordinator.sock",
              timeout=10,
          )

      with subtest("spawn probe-wayland through the coordinator"):
          # The coordinator socket is mode 0600 owned by test; quoting
          # via printf so socat's stdin doesn't get split.
          out = machine.succeed(
              "printf '%s\\n' '{\"op\":\"spawn\",\"app\":\"probe-wayland\"}' | "
              "sudo -u test socat - UNIX-CONNECT:/run/user/1000/spaces-app-coordinator.sock"
          )
          assert '"op":"ok"' in out, out

      with subtest("wayland-info reached the sandboxed registry"):
          # wayland-info writes to stderr; the unit captures that into
          # the user journal. Wait until at least the baseline
          # wl_compositor line lands, then read the full block.
          machine.wait_until_succeeds(
              "sudo -u test XDG_RUNTIME_DIR=/run/user/1000 "
              "journalctl --user --since '30 sec ago' -o cat | grep -q 'wl_compositor'",
              timeout=30,
          )

      with subtest("security-context filters every restricted global"):
          journal = machine.succeed(
              "sudo -u test XDG_RUNTIME_DIR=/run/user/1000 "
              "journalctl --user --since '60 sec ago' -o cat"
          )

          # Each of these Wayland protocol globals is gated by niri on
          # `client_is_unrestricted` (see niri/src/niri.rs around the
          # ScreencopyManagerState / ForeignToplevelManagerState /
          # WlrDataControlState / VirtualKeyboardManagerState /
          # WlrLayerShellState / SessionLockManagerState /
          # InputMethodManagerState / SecurityContextState
          # construction). A client coming in via the security-context
          # listener has `restricted: true` and must NOT see any of
          # these in its registry.
          restricted_globals = [
              "wlr_screencopy",
              "wp_security_context_manager",
              "foreign_toplevel",
              "wlr_data_control",
              "ext_data_control",
              "virtual_keyboard",
              "virtual_pointer",
              "zwlr_layer_shell",
              "session_lock",
              "input_method",
          ]
          leaked = [g for g in restricted_globals if g in journal]
          assert not leaked, (
              f"sandboxed client saw {leaked!r}; "
              f"security-context-v1 enforcement is not engaging. "
              f"journal:\n{journal}"
          )

      with subtest("baseline globals still reach the sandboxed client"):
          journal = machine.succeed(
              "sudo -u test XDG_RUNTIME_DIR=/run/user/1000 "
              "journalctl --user --since '60 sec ago' -o cat"
          )
          for required in ("wl_compositor", "wl_shm", "xdg_wm_base"):
              assert required in journal, (
                  f"required global {required!r} missing; the sandbox "
                  f"connected but the Wayland session is broken"
              )

      with subtest("waylandSandbox=false → restricted globals reach the client"):
          # The probe-wayland-raw app has `wayland` granted but
          # `waylandSandbox = false`, so the wayland-app-context wrap
          # is skipped. wayland-info should now see the *full*
          # registry — including the protocols Niri filters for
          # security-context clients. This is the regression test
          # for the voxtype-style "I need virtual-keyboard" use case.
          machine.succeed(
              "printf '%s\\n' '{\"op\":\"spawn\",\"app\":\"probe-wayland-raw\"}' | "
              "sudo -u test socat - UNIX-CONNECT:/run/user/1000/spaces-app-coordinator.sock"
          )
          machine.wait_until_succeeds(
              "sudo -u test XDG_RUNTIME_DIR=/run/user/1000 "
              "journalctl --user --since '20 sec ago' -u 'app-probe-wayland-raw-*' -o cat | grep -q 'zwlr_screencopy_manager_v1'",
              timeout=15,
          )
          journal = machine.succeed(
              "sudo -u test XDG_RUNTIME_DIR=/run/user/1000 "
              "journalctl --user --since '20 sec ago' -u 'app-probe-wayland-raw-*' -o cat"
          )
          # All the restricted globals should now be visible. If any
          # are missing it means the security-context wrap is being
          # applied despite `waylandSandbox = false`.
          must_be_visible = [
              "zwlr_screencopy_manager_v1",
              "wp_security_context_manager_v1",
              "zwlr_foreign_toplevel_manager_v1",
              "zwlr_layer_shell_v1",
          ]
          missing = [g for g in must_be_visible if g not in journal]
          assert not missing, (
              f"waylandSandbox=false should expose {missing!r} but they "
              f"didn't reach the client. journal:\n{journal}"
          )
    '';
  }
