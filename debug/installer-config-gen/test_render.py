"""Unit tests for the patched Calamares `nixos` job module.

Exercises the pure builder functions (`render_configuration`,
`render_flake_nix`) against a stubbed `libcalamares.globalstorage`. The
side-effecting `run()` orchestrator is out of scope — that needs the
real Calamares host-env helpers and a mounted target.

This is the primary iteration loop while shaping the patched script:
```
nix build .#debug.x86_64-linux.installer-config-gen
```
"""

import os
import subprocess
import sys
import unittest

# Inject the patched main.py and our libcalamares stub.
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

# `main.py` shells out twice from inside `render_configuration`:
#   - `subprocess.getoutput(['nixos-version'])` for `system.stateVersion`,
#   - `subprocess.check_output(['pkexec', 'loadkeys', …])` to apply the
#      chosen console keymap to the live ISO.
# Neither makes sense in a unit test (no live console, the nix sandbox
# has no `/usr/bin/env` for shebangs anyway). Stub both before `main`
# imports so render_configuration sees deterministic results.
subprocess.getoutput = lambda _argv: "25.05.20260422.deadbee (Foo)"
_real_check_output = subprocess.check_output


def _stub_check_output(argv, *a, **kw):
    if isinstance(argv, (list, tuple)) and argv and argv[0] == "pkexec":
        return b""
    return _real_check_output(argv, *a, **kw)


subprocess.check_output = _stub_check_output

import libcalamares  # noqa: E402, F401 — must register before main.py imports it
import main  # noqa: E402

# Representative fixture: EFI boot, no LUKS, en_US locale, US keyboard.
BASE_GS = {
    "rootMountPoint": "/mnt",
    "firmwareType": "efi",
    "bootLoader": {"installPath": "/boot"},
    "partitions": [
        {
            "mountPoint": "/",
            "fs": "ext4",
            "fsName": "ext4",
            "claimed": True,
            "device": "/dev/vda1",
            "uuid": "00000000-0000-0000-0000-000000000001",
        }
    ],
    "hostname": "ai-desktop",
    "username": "alice",
    "fullname": "Alice Example",
    "locationRegion": "Europe",
    "locationZone": "Berlin",
    "localeConf": {
        "LANG": "en_US.UTF-8/UTF-8",
        "LC_ADDRESS": "en_US.UTF-8/UTF-8",
        "LC_IDENTIFICATION": "en_US.UTF-8/UTF-8",
        "LC_MEASUREMENT": "en_US.UTF-8/UTF-8",
        "LC_MONETARY": "en_US.UTF-8/UTF-8",
        "LC_NAME": "en_US.UTF-8/UTF-8",
        "LC_NUMERIC": "en_US.UTF-8/UTF-8",
        "LC_PAPER": "en_US.UTF-8/UTF-8",
        "LC_TELEPHONE": "en_US.UTF-8/UTF-8",
        "LC_TIME": "en_US.UTF-8/UTF-8",
    },
    "keyboardLayout": "us",
    "keyboardVariant": "",
    "keyboardVConsoleKeymap": "us",
}


class RenderConfigurationTests(unittest.TestCase):
    def setUp(self):
        libcalamares.globalstorage.reset(BASE_GS)
        # ngc_cfg only consulted for `Defaults.Kernel`; default works.

        class _NgcStub:
            def __getitem__(self, _):
                return {"Kernel": "lts"}

        self.ngc = _NgcStub()

    def render(self, overrides=None):
        if overrides:
            data = dict(BASE_GS)
            data.update(overrides)
            libcalamares.globalstorage.reset(data)
        return main.render_configuration(libcalamares.globalstorage, self.ngc)

    # --- structure ---------------------------------------------------------

    def test_emits_thin_overlay_module_header(self):
        cfg = self.render()
        self.assertIn("{ ... }:", cfg)
        # No standalone-mode imports — spaces module + hardware-config come
        # in via the wrapper flake.
        self.assertNotIn("./hardware-configuration.nix", cfg)
        self.assertNotIn("imports", cfg)

    def test_no_unresolved_template_placeholders(self):
        cfg = self.render()
        leftover = [line for line in cfg.splitlines() if "@@" in line]
        self.assertEqual(leftover, [], "unresolved @@…@@ placeholders remain")

    def test_state_version_substituted(self):
        cfg = self.render()
        self.assertIn('system.stateVersion = "25.05";', cfg)

    # --- bootloader --------------------------------------------------------

    def test_efi_emits_systemd_boot(self):
        cfg = self.render()
        self.assertIn("boot.loader.systemd-boot.enable = true;", cfg)
        self.assertNotIn("boot.loader.grub.enable", cfg)

    def test_bios_ext4_emits_grub(self):
        cfg = self.render(
            {
                "firmwareType": "bios",
                "bootLoader": {"installPath": "/dev/vda"},
            }
        )
        self.assertIn('boot.loader.grub.device = "/dev/vda";', cfg)
        self.assertNotIn("fsIdentifier", cfg)

    def test_bios_btrfs_uses_provided_fs_identifier(self):
        cfg = self.render(
            {
                "firmwareType": "bios",
                "bootLoader": {"installPath": "/dev/vda"},
                "partitions": [
                    {
                        "mountPoint": "/",
                        "fs": "btrfs",
                        "fsName": "btrfs",
                        "claimed": True,
                        "device": "/dev/vda1",
                        "uuid": "x",
                    }
                ],
            }
        )
        self.assertIn('boot.loader.grub.fsIdentifier = "provided";', cfg)

    # --- networking / locale / time ---------------------------------------

    def test_networkmanager_enabled_unconditionally(self):
        cfg = self.render()
        self.assertIn("networking.networkmanager.enable = true;", cfg)

    def test_timezone_concatenated(self):
        cfg = self.render()
        self.assertIn('time.timeZone = "Europe/Berlin";', cfg)

    def test_default_locale_uses_LANG_only(self):
        cfg = self.render()
        self.assertIn('i18n.defaultLocale = "en_US.UTF-8";', cfg)
        # Upstream emits an `extraLocaleSettings` block whenever the
        # raw locale strings (pre-/UTF-8-suffix-split) differ from LANG.
        # With LANG=en_US.UTF-8/UTF-8 the LC_* values still carry the
        # /UTF-8 suffix, so the block is emitted but every value
        # collapses back to the LANG value once split.
        self.assertIn('LC_TIME = "en_US.UTF-8";', cfg)

    def test_mixed_locale_emits_extra_settings(self):
        mixed = dict(BASE_GS["localeConf"])
        mixed["LC_TIME"] = "de_DE.UTF-8/UTF-8"
        cfg = self.render({"localeConf": mixed})
        self.assertIn("extraLocaleSettings", cfg)
        self.assertIn('LC_TIME = "de_DE.UTF-8";', cfg)

    # --- keyboard ----------------------------------------------------------

    def test_keymap_emitted(self):
        cfg = self.render()
        self.assertIn('layout = "us";', cfg)

    # --- users / greetd ----------------------------------------------------

    def test_user_account_emitted(self):
        cfg = self.render()
        self.assertIn("users.users.alice = {", cfg)
        self.assertIn('description = "Alice Example";', cfg)
        self.assertIn('extraGroups = [ "networkmanager" "wheel" ];', cfg)

    def test_greetd_default_user_overridden(self):
        cfg = self.render()
        self.assertIn('services.greetd.settings.default_session.user = "alice";', cfg)

    # --- DE branching is gone ---------------------------------------------

    def test_no_desktop_environment_assertions(self):
        cfg = self.render()
        for de in ("gnome", "plasma6", "xfce", "pantheon", "cinnamon", "mate"):
            self.assertNotIn(f"desktopManager.{de}", cfg)
        self.assertNotIn("displayManager.gdm", cfg)
        self.assertNotIn("displayManager.sddm", cfg)
        self.assertNotIn("displayManager.lightdm", cfg)


class RenderFlakeNixTests(unittest.TestCase):
    def setUp(self):
        libcalamares.globalstorage.reset(BASE_GS)

    def test_spaces_input_points_at_upstream_github(self):
        # The wrapper flake's `inputs.spaces.url` is canonical upstream;
        # the lock pins it to a local store path. Verifying the URL
        # here keeps the production-vs-test framing visible at the unit
        # level.
        expr = main.render_flake_nix(libcalamares.globalstorage)
        self.assertIn(
            'inputs.spaces.url = "github:generational-infrastructure/spaces-os";',
            expr,
        )

    def test_calls_spaces_lib_mksystem(self):
        expr = main.render_flake_nix(libcalamares.globalstorage)
        self.assertIn("inputs.spaces.lib.mkSystem", expr)
        self.assertIn('hostName = "ai-desktop";', expr)

    def test_emits_named_nixos_configuration(self):
        # nixos-install consumes `nixosConfigurations.<host>`; the
        # generated flake MUST expose that attribute under the GS
        # hostname.
        expr = main.render_flake_nix(libcalamares.globalstorage)
        self.assertIn("nixosConfigurations.ai-desktop", expr)

    def test_modules_list_contains_both_files(self):
        expr = main.render_flake_nix(libcalamares.globalstorage)
        self.assertIn("./configuration.nix", expr)
        self.assertIn("./hardware-configuration.nix", expr)

    def test_system_matches_host_arch(self):
        expr = main.render_flake_nix(libcalamares.globalstorage)
        self.assertIn(f'system = "{os.uname().machine}-linux";', expr)


if __name__ == "__main__":
    unittest.main()
