# End-to-end graphical installer test.
#
# Boots a live environment identical to the installer ISO (GNOME +
# Calamares with our spaces overlay), drives the full Calamares wizard
# via OCR + keyboard, then reboots into the installed system and
# verifies that the niri compositor and pi-chat panel actually launched.
#
# Two phases, one test:
#   Phase 1 — `installer` node: GNOME + Calamares live env.  OCR
#     navigates welcome → locale → keyboard → users → partition →
#     summary → exec → finished.
#   Phase 2 — raw QEMU launched from the test script (host-side
#     Python) boots the disk Calamares partitioned.  Serial console +
#     QEMU-monitor screendumps + tesseract verify niri + pi-chat.
#
# Debugging: build with `--keep-failed` to preserve the output directory
# on failure.  Screenshots (*.png) are saved at each wizard step and can
# be inspected to diagnose OCR / click-coordinate issues.
#
# Requires `/dev/kvm` and significant RAM (~8 GiB).
{
  pkgs,
  inputs,
  flake,
  ...
}:
let
  inherit (pkgs) lib;
  inherit (flake.lib) spacesSrc;

  # Mirror the override-map computation done by modules/nixos/installer-iso.nix
  # so this VM's calamares main.py sees the same install-time config.
  spacesLock = builtins.fromJSON (builtins.readFile "${spacesSrc}/flake.lock");
  spacesDirectInputNames = builtins.attrNames spacesLock.nodes.root.inputs;
  inputOverrides = lib.genAttrs (builtins.filter (n: inputs ? ${n}) spacesDirectInputNames) (
    n: builtins.toString inputs.${n}.outPath
  );
  installConfig = pkgs.writeText "calamares-spaces-install.json" (
    builtins.toJSON {
      spacesFlake = toString spacesSrc;
      inherit inputOverrides;
    }
  );

  # OVMF firmware for phase-2 QEMU (EFI boot into systemd-boot).
  ovmfFd = (pkgs.OVMF.override { secureBoot = false; }).fd;

  baseTest = pkgs.testers.runNixOSTest {
    name = "installer-gui-end-to-end";
    node.specialArgs = { inherit inputs; };
    # Allow nixpkgs.overlays in nodes so we can shadow
    # calamares-nixos-extensions with our fork.
    node.pkgsReadOnly = false;
    enableOCR = true;

    nodes.installer =
      { lib, ... }:
      {
        imports = [
          "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-calamares-gnome.nix"
        ];

        # Shadow upstream calamares-nixos-extensions with our fork.
        # mkForce to override the installation-device profile's overlay.
        nixpkgs.overlays = lib.mkForce [
          (final: prev: {
            calamares-nixos-extensions = final.callPackage ../packages/calamares-spaces-extensions {
              base = prev.calamares-nixos-extensions;
            };
          })
        ];

        # Install-time config for the patched main.py (spacesSrc store
        # path + per-input overrides). Lives outside the calamares
        # package so package builds aren't invalidated by repo edits.
        environment.etc."calamares-spaces/install.json".source = installConfig;

        # EFI so Calamares detects firmwareType=efi → systemd-boot.
        virtualisation.useEFIBoot = true;

        virtualisation = {
          memorySize = 8192;
          cores = 4;
          # Target disk for the installation.  Shows up as /dev/vdb.
          diskSize = 16384; # 16 GiB — nix-build eval cache + intermediate derivations need room
          emptyDiskImages = [ 32768 ];
          resolution = {
            x = 1280;
            y = 800;
          };
        };

        # Pre-stage the spaces flake + installer-target closure into the
        # VM's nix store so Calamares's `nix-build` + `nixos-install`
        # can resolve everything without network access.
        environment.etc."installer-store-paths".text = builtins.concatStringsSep "\n" [
          "${spacesSrc}"
          "${flake.nixosConfigurations.installer-target.config.system.build.toplevel}"
          "${inputs.nixpkgs.outPath}"
          # Flake input outPaths for evaluation.
          "${inputs.blueprint.outPath}"
          "${inputs.treefmt-nix.outPath}"
          "${inputs.llm-agents.outPath}"
        ];

        # Tell Calamares's main.py to include spaces.nixosModules.test-support
        # in the installed system's default.nix.  This adds serial console +
        # patched niri (software EGL rendering) so Phase 2 can verify niri
        # actually renders a desktop on the freshly booted disk.
        # File-based sentinel: main.py checks /etc/spaces-test-support because
        # GDM/GNOME sessions don't reliably inherit environment.variables.
        environment.etc."spaces-test-support".text = "1";

        # Forward kernel + journal to ttyS0 so the test sees nix-build
        # progress (pkexec captures stdout, otherwise invisible).
        boot.kernelParams = [
          "console=tty0"
          "console=ttyS0,115200n8"
        ];
        services.journald.extraConfig = ''
          ForwardToConsole=yes
          MaxLevelConsole=info
        '';
        virtualisation.writableStore = true;
        # Back the writable store with disk, not tmpfs — nix-build's
        # eval cache + intermediate derivations exceed the default
        # tmpfs size.
        virtualisation.writableStoreUseTmpfs = false;

        # Network access so nix-build can resolve flake inputs.
        # QEMU user-mode networking provides DNS at 10.0.2.3.
        networking.useDHCP = lib.mkForce true;
        networking.nameservers = lib.mkForce [ "10.0.2.3" ];
        # Bypass NetworkManager's resolv.conf management.
        environment.etc."resolv.conf".text = lib.mkForce "nameserver 10.0.2.3\n";
      };

    testScript =
      { nodes, ... }:
      ''
        import subprocess
        import shutil
        import time
        import os
        import socket
        import re
        import tempfile

        # ── Diagnostic helpers ──────────────────────────────────────

        def dump_state(machine, tag):
            """Dump system state for debugging when something goes wrong."""
            machine.screenshot(f"diag-{tag}")
            text = machine.get_screen_text()
            print(f"\n=== OCR at {tag} ===\n{text}\n=== end OCR ===")
            for cmd in [
                "systemctl --no-pager status display-manager gdm || true",
                "systemctl --no-pager --user -M nixos@.host list-units --state=running || true",
                "pgrep -a calamares || echo 'no calamares process'",
                "pgrep -a gnome-shell || echo 'no gnome-shell process'",
                "journalctl --no-pager -b -p err --lines=30 || true",
                "journalctl --no-pager -b -u gdm --lines=20 || true",
                "journalctl --no-pager -b --user -M nixos@.host --lines=30 || true",
            ]:
                print(f"\n>>> {cmd}")
                out = machine.execute(cmd)[1]
                print(out[:2000])

        def wait_for_text_or_diag(machine, pattern, timeout, tag):
            """Manual OCR loop with diagnostics. Uses get_screen_text()"""
            deadline = time.monotonic() + timeout
            last_text = ""
            while time.monotonic() < deadline:
                text = machine.get_screen_text()
                last_text = text
                if re.search(pattern, text, re.IGNORECASE):
                    return
                time.sleep(2)
            print(f"wait_for_text_or_diag('{pattern}') timed out after {timeout}s")
            print(f"Last OCR text: {last_text[:500]}")
            dump_state(machine, tag)
            raise Exception(f"OCR pattern '{pattern}' not found within {timeout}s")

        # Screen dimensions (GNOME default in QEMU).
        SCREEN_W, SCREEN_H = 1280, 800

        def mouse_click(machine, px, py):
            """Click at pixel (px, py) using QMP input-send-event.
            Converts to 0-32767 absolute range for usb-tablet."""
            ax = int(px * 32767 / SCREEN_W)
            ay = int(py * 32767 / SCREEN_H)
            # QMP input-send-event: move + press in one call.
            machine.qmp_client.send("input-send-event", {
                "events": [
                    {"type": "abs", "data": {"axis": "x", "value": ax}},
                    {"type": "abs", "data": {"axis": "y", "value": ay}},
                    {"type": "btn", "data": {"button": "left", "down": True}},
                ]
            })
            time.sleep(0.1)
            # Release.
            machine.qmp_client.send("input-send-event", {
                "events": [
                    {"type": "abs", "data": {"axis": "x", "value": ax}},
                    {"type": "abs", "data": {"axis": "y", "value": ay}},
                    {"type": "btn", "data": {"button": "left", "down": False}},
                ]
            })
        # ── Phase 1: Boot live env and drive Calamares ──────────────

        installer.start()
        installer.wait_for_unit("display-manager.service", timeout=120)

        # Diagnostic: what does the screen look like after GDM starts?
        installer.sleep(5)
        installer.screenshot("00-after-gdm")
        text = installer.get_screen_text()
        print(f"Screen after GDM: {text[:300]}")

        # Check GDM autologin + GNOME session state
        installer.wait_until_succeeds(
            "systemctl --user -M nixos@.host is-active gnome-shell-wayland.target 2>/dev/null"
            " || systemctl --user -M nixos@.host is-active graphical-session.target 2>/dev/null"
            " || pgrep -u nixos gnome-shell",
            timeout=60,
        )
        print("GNOME session is active.")

        # Check if calamares process is running
        installer.wait_until_succeeds(
            "pgrep -f calamares",
            timeout=60,
        )
        print("Calamares process detected.")

        # Give Calamares time to render its window.
        installer.sleep(10)
        installer.screenshot("00b-calamares-starting")

        # The GNOME desktop may show Activities overview on first login,
        # hiding the Calamares window.  Dismiss it with Escape.
        installer.send_key("esc")
        installer.sleep(2)
        installer.send_key("esc")
        installer.sleep(2)
        installer.screenshot("00c-after-escape")
        text = installer.get_screen_text()
        print(f"Screen after escape: {text[:500]}")

        # Calamares welcome page shows sidebar with "Install", "Finish",
        # "Release notes", "Cancel" etc.  Verify it's there via manual
        # OCR loop for better diagnostic output.
        calamares_found = False
        for attempt in range(30):  # 30s
            text = installer.get_screen_text()
            print(f"Welcome OCR attempt {attempt}: {text[:200]}")
            if re.search(r"(Release notes|Cancel|American English|Partitions|Summary|Finish)", text):
                calamares_found = True
                break
            installer.sleep(1)
        if not calamares_found:
            dump_state(installer, "welcome-not-found")
            raise Exception("Calamares welcome page not detected")

        # Maximize Calamares window so button positions are deterministic.
        # Click window to focus, then Super+Up to maximize.
        mouse_click(installer, 640, 400)
        time.sleep(1)
        installer.send_key("meta_l-up")
        installer.sleep(2)
        installer.screenshot("01-welcome-maximized")

        # After maximizing at 1280x800 (measured from screenshot):
        # - Window fills screen below GNOME top bar (y=26..800)
        # - Sidebar: x=0..155
        # - Next button: ~(1133, 783)
        # - Back button: ~(1047, 783)
        # - Cancel button: ~(1227, 783)
        # - Content area starts at x~170, y~65

        NEXT_X, NEXT_Y = 1133, 783

        def click_next():
            """Advance Calamares to the next page."""
            # Click content area (not sidebar!) to ensure focus.
            mouse_click(installer, 700, 300)
            time.sleep(1)
            mouse_click(installer, NEXT_X, NEXT_Y)
            installer.sleep(3)
            text = installer.get_screen_text()
            print(f"After click_next: {text[:300]}")

        # Page 1: Welcome - body says "Welcome to the NixOS installer".
        installer.sleep(2)
        click_next()

        # Page 2: Location - body shows "system language will be set to".
        wait_for_text_or_diag(installer, "(system language|numbers and dates|locale will be set)", 30, "locale-wait")
        installer.screenshot("02-locale")
        click_next()

        # Page 3: Keyboard - body has "Type here to test your keyboard".
        wait_for_text_or_diag(installer, "(Type here|test your keyboard|Keyboard Model)", 30, "keyboard-wait")
        installer.screenshot("03-keyboard")
        click_next()

        # Page 4: Users - body has "What is your name" / password fields.
        wait_for_text_or_diag(installer, "(What is your name|Choose a password|computer name|Log in automatically)", 30, "users-wait")
        installer.screenshot("04-users-before")

        # Click the full name field (maximized layout: ~275, 116).
        mouse_click(installer, 275, 116)
        installer.sleep(1)
        installer.send_chars("Test User")
        installer.sleep(2)
        # Tab: name -> login (auto-filled, skip) -> password1 -> password2.
        installer.send_key("tab")  # -> login name
        installer.sleep(1)
        installer.send_key("tab")  # -> password1
        installer.sleep(1)
        installer.send_chars("xK9#mP2!vL")
        installer.sleep(1)
        installer.send_key("tab")  # -> password2 (confirm)
        installer.sleep(1)
        installer.send_chars("xK9#mP2!vL")
        installer.sleep(1)
        # Tab to "Require strong passwords" checkbox and uncheck it.
        installer.send_key("tab")
        installer.sleep(1)
        installer.send_key("spc")  # uncheck
        installer.sleep(1)
        # Check "Use the same password for the administrator account".
        installer.send_key("tab")
        installer.sleep(1)
        installer.send_key("spc")  # check
        installer.sleep(2)
        installer.screenshot("04-users-after")
        click_next()

        # Page 5: Partitions - body shows disk/partition selector.
        wait_for_text_or_diag(installer, "(Erase disk|Select storage|storage device|current device)", 30, "partition-wait")
        installer.screenshot("05-partition")
        # Select "Erase disk" radio button (maximized: ~185, 131).
        mouse_click(installer, 185, 131)
        installer.sleep(2)
        installer.screenshot("05b-partition-erase-selected")
        click_next()

        # Page 6: Summary - shows overview of what will happen.
        # If the install fails fast, we might land on the Finish page
        # with an error dialog instead of seeing Summary.
        wait_for_text_or_diag(installer, "(overview of what will happen|will be set|GPT partition|Installation Failed|All done)", 30, "summary-wait")
        installer.screenshot("06-summary")
        # The Install button is in the same place as Next.
        click_next()

        # Calamares may show a confirmation dialog.  Handle it.
        installer.sleep(3)
        text = installer.get_screen_text()
        if re.search(r"(Install now|Continue|proceed|confirm)", text, re.IGNORECASE):
            # Confirmation dialog — click Install/Yes/Continue.
            mouse_click(installer, 640, 484)  # centered Yes/Install button
            installer.sleep(2)

        # -- Wait for the exec phase to complete --
        # partition -> mount -> nixos (nix-build + nixos-install) -> users -> umount.
        # Periodically tail calamares.log so we can see nix-build progress
        # in the test output instead of staring at a black box.
        install_deadline = time.monotonic() + 1800
        last_log_size = 0
        done_pattern = re.compile(r"(finished|Finished|complete|All done|restart|Restart|Done|Installation Failed)")
        while time.monotonic() < install_deadline:
            # Tail new bytes from calamares.log.
            status, log_path = installer.execute(
                "ls -1t /var/log/calamares/Calamares-*.log 2>/dev/null | head -1"
            )
            if status == 0 and log_path.strip():
                status, log_size = installer.execute(
                    f"stat -c%s {log_path.strip()}"
                )
                if status == 0:
                    size = int(log_size.strip() or 0)
                    if size > last_log_size:
                        _, new_text = installer.execute(
                            f"tail -c +{last_log_size + 1} {log_path.strip()} | tail -c 8000"
                        )
                        print(f"--- calamares.log delta ---\n{new_text}")
                        last_log_size = size
            # Check OCR for completion.
            text = installer.get_screen_text()
            if done_pattern.search(text):
                break
            time.sleep(15)
        else:
            dump_state(installer, "install-exec")
            raise Exception("Install exec phase did not complete within 1800s")
        installer.screenshot("07-finished")

        # Check if installation failed.
        text = installer.get_screen_text()
        if re.search(r"(Installation Failed|Error|failed)", text):
            print(f"Installation failed. Screen: {text[:500]}")
            dump_state(installer, "install-failed")
            raise Exception("Installation failed — see screenshots and logs")

        installer.shutdown()
        # ── Phase 2: Boot the installed system ─────────────────────
        #
        # Launch a raw QEMU from the test script (host-side Python)
        # to boot the disk Calamares partitioned.  The installed system
        # does not have test-instrumentation, so we cannot use shell
        # commands.  Verification is entirely via QEMU monitor
        # screendumps + tesseract OCR.

        # The installed disk is the first emptyDiskImages entry.
        installed_disk = os.path.join(installer.state_dir, "empty0.qcow2")
        assert os.path.exists(installed_disk), f"Installed disk not found: {installed_disk}"

        # Set up a temporary directory for phase-2 state.
        phase2_dir = tempfile.mkdtemp(prefix="installer-gui-end-to-end-phase2-")
        serial_log = os.path.join(phase2_dir, "serial.log")
        monitor_sock = os.path.join(phase2_dir, "monitor.sock")

        # Copy EFI vars template (needs to be writable).
        efi_vars = os.path.join(phase2_dir, "efi-vars.fd")
        shutil.copy("${ovmfFd}/FV/OVMF_VARS.fd", efi_vars)
        os.chmod(efi_vars, 0o644)

        qemu_cmd = [
            "${pkgs.qemu}/bin/qemu-system-x86_64",
            "-machine", "accel=kvm:tcg", "-cpu", "max",
            "-m", "4G", "-smp", "4",
            "-drive", f"file={installed_disk},format=qcow2,if=virtio",
            "-drive", "if=pflash,format=raw,unit=0,readonly=on,"
                      "file=${ovmfFd}/FV/OVMF_CODE.fd",
            "-drive", f"if=pflash,format=raw,unit=1,readonly=off,file={efi_vars}",
            # Use default VGA (same as NixOS test framework's QEMU).  The
            # kernel picks up the EFI framebuffer via simpledrm, which
            # provides DRM for niri/wlroots.  The niri-render-smoke test
            # proves this works with software EGL rendering.
            "-display", "none",
            "-serial", f"file:{serial_log}",
            "-monitor", f"unix:{monitor_sock},server,nowait",
            "-no-reboot",
        ]

        # Touch serial log so reads don't fail before QEMU writes.
        open(serial_log, "w").close()

        proc = subprocess.Popen(qemu_cmd)

        def cleanup_phase2():
            if proc.poll() is None:
                proc.kill()
                proc.wait()

        import atexit
        atexit.register(cleanup_phase2)

        def read_serial():
            with open(serial_log, "r", errors="replace") as f:
                return f.read()

        # Persistent monitor connection (mutable container because
        # top-level exec scope has no nonlocal).
        _monitor = [None]

        def monitor_connect():
            if _monitor[0] is not None:
                return
            # QEMU monitor socket may take a moment to become available.
            for _ in range(30):
                try:
                    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    s.connect(monitor_sock)
                    # Drain the greeting / prompt.
                    time.sleep(0.5)
                    s.recv(4096)
                    _monitor[0] = s
                    return
                except (ConnectionRefusedError, FileNotFoundError):
                    time.sleep(1)
            raise Exception("Could not connect to QEMU monitor")

        def monitor_cmd(cmd):
            """Send a command to the QEMU human monitor."""
            monitor_connect()
            _monitor[0].sendall(f"{cmd}\n".encode())
            time.sleep(1)
            resp = _monitor[0].recv(65536).decode(errors="replace")
            return resp

        def take_screenshot(name):
            """Take a screenshot via QEMU monitor and run OCR."""
            ppm = os.path.join(phase2_dir, f"{name}.ppm")
            monitor_cmd(f"screendump {ppm}")
            time.sleep(0.5)
            if not os.path.exists(ppm):
                print(f"WARNING: screenshot {ppm} not created")
                return ""
            # Copy to test output dir for inspection.
            out_dir = os.environ.get("out", phase2_dir)
            os.makedirs(out_dir, exist_ok=True)
            shutil.copy(ppm, os.path.join(out_dir, f"{name}.ppm"))
            # OCR via tesseract.
            try:
                result = subprocess.run(
                    ["tesseract", ppm, "stdout"],
                    capture_output=True, text=True, timeout=30,
                )
                text = result.stdout
                print(f"OCR [{name}]: {text[:500]}")
                return text
            except Exception as exc:
                print(f"OCR failed for {name}: {exc}")
                return ""

        # Wait for QEMU to start and the installed system to boot.
        # Give plenty of time for OVMF + systemd + greetd + niri.
        time.sleep(30)

        # Verify QEMU is still alive.
        assert proc.poll() is None, (
            f"QEMU exited immediately ({proc.returncode}).\n"
            f"Serial: {read_serial()[-2000:]}"
        )

        with subtest("Phase 2: installed system boots, niri renders wallpaper"):
            # Boot budget: OVMF + systemd + greetd + niri + swaybg fits in ≤90s
            # on a healthy host.  If 90s isn't enough, something is broken
            # (stuck on bootloader, niri crash loop, etc.) — fail loud.
            print(f"Phase 2 screenshot dir: {phase2_dir}")
            # niri shows an "Important Hotkeys" overlay on first launch that
            # covers the wallpaper.  Dismiss it with Escape via the QEMU
            # monitor so OCR can see the SPACES_TEST_OK marker behind it.
            # Same trick as checks/niri-render-smoke.nix.
            dismissed_overlay = False
            found_marker = False
            last_ppm = None
            # 9 × 10s = 90s.  Already slept 30s above for QEMU/OVMF startup,
            # so total budget from QEMU launch is ~120s.
            for attempt in range(9):
                if proc.poll() is not None:
                    print(f"Serial log:\n{read_serial()[-3000:]}")
                    raise Exception(
                        f"QEMU exited ({proc.returncode}) during Phase 2"
                    )
                text = take_screenshot(f"phase2-{attempt:02d}")
                last_ppm = os.path.join(phase2_dir, f"phase2-{attempt:02d}.ppm")
                # Once niri is up enough to render, dismiss the hotkey overlay
                # exactly once.  Heuristic: any visible text on screen means
                # the compositor is rendering, so a keypress will be consumed.
                if not dismissed_overlay and text.strip():
                    monitor_cmd("sendkey esc")
                    dismissed_overlay = True
                    time.sleep(2)
                    continue
                if re.search(r"SPACES[_\s]+TEST[_\s]+OK", text):
                    print(f"Wallpaper marker detected (attempt {attempt})")
                    found_marker = True
                    break
                # Print serial log progress every 3 iterations for diagnostics.
                if attempt % 3 == 2:
                    print(f"Serial log (attempt {attempt}):\n{read_serial()[-2000:]}")
                time.sleep(10)
            if not found_marker:
                print(f"Serial log tail:\n{read_serial()[-5000:]}")
                print("=" * 70)
                print("Phase 2 boot timeout — SPACES_TEST_OK marker not detected in 90s.")
                print(f"Last screenshot: {last_ppm}")
                print(f"All Phase 2 screenshots: {phase2_dir}/phase2-*.ppm")
                print("")
                print("HINT for future agents: re-run the build with --keep-failed")
                print("to preserve the build sandbox, then read the .ppm files at")
                print("the path printed above to inspect what actually rendered.")
                print("  nix build -L .#debug.x86_64-linux.installer-gui-end-to-end --keep-failed")
                print("  ls /tmp/nix-build-vm-test-run-installer-gui-end-to-end.drv-*/installer-gui-end-to-end-phase2-*/")
                print("=" * 70)
            assert found_marker, (
                "SPACES_TEST_OK wallpaper marker not detected within 90s. "
                f"Last screenshot: {last_ppm}. "
                "See log above for re-run hint."
            )

        # Final evidence screenshot.
        take_screenshot("final-desktop")

        # Dump serial log for debugging (OVMF + bootloader output).
        print(f"Phase 2 serial log:\n{read_serial()[-3000:]}")

        # Clean shutdown.
        try:
            monitor_cmd("system_powerdown")
            proc.wait(timeout=30)
        except Exception:
            proc.kill()
            proc.wait()

        print("All phases passed.")
      '';
  };
in
# __impure grants the build sandbox network access so that nix-build
# inside the VM can fetch flake input tarballs via fetchTree.
baseTest.overrideTestDerivation (_prev: {
  __impure = true;
})
