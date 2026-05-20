# NixOS VM test for the test-machine host.
#
# Dual-mode: defaults to the local llama-swap backend; if the
# `OPENROUTER_API_KEY` environment variable is set at eval time, the
# test switches the in-VM opencrow to the openrouter provider and runs
# a real round-trip against api.openrouter.ai instead.
#
#   nix build .#checks.x86_64-linux.test-machine                  # local
#   nix build --impure .#checks.x86_64-linux.test-machine          # local (env unset)
#   OPENROUTER_API_KEY=sk-or-... nix build --impure ...            # openrouter
#
# Reading the env var requires `--impure`; under `nix flake check`
# (pure eval) the key is invisible and the test always runs in local
# mode. Repo-local secret loading via direnv is documented in
# `README.md` and `.env.example`.
#
# Headless verification of the wiring around niri, the noctalia
# opencrow-chat plugin, opencrow socket backend, and llama-swap
# (or openrouter):
#   - greetd starts and opens a PAM session for the test user
#   - the user manager (user@1000.service) comes up
#   - niri.service activates and exposes a Wayland socket
#   - noctalia-shell.service starts under graphical-session.target
#   - opencrow-chat plugin is symlinked into the test user's noctalia dir
#   - opencrow container comes up with socket backend
#   - the chat socket is accessible on the host
#   - a message sent through the socket reaches opencrow and a reply
#     comes back (via local model or openrouter, depending on mode)
#
# Interactive validation of the shell happens in the GUI VM
# (`nix build .#test-vm && ./result/bin/run-test-machine-vm`).
{ pkgs, inputs, ... }:

let
  inherit (pkgs) lib;

  openrouterKey = builtins.getEnv "OPENROUTER_API_KEY";
  useOpenrouter = openrouterKey != "";

  # Small, cheap, fast. Swap to taste; the chat round-trip only asserts
  # a non-empty reply, not specific content.
  openrouterModel = "google/gemma-4-26b-a4b-it";

  apiKeyFile = if useOpenrouter then pkgs.writeText "openrouter-api-key" openrouterKey else null;

  testChat = ./test-opencrow-chat.py;

  baseTest = pkgs.testers.runNixOSTest {
    name = "test-machine${lib.optionalString useOpenrouter "-openrouter"}";
    node.specialArgs = { inherit inputs; };

    nodes.test-machine =
      { lib, pkgs, ... }:
      {
        imports = [
          inputs.self.nixosModules.distro
          ../hosts/test-machine/configuration.nix
        ];

        # The host pins a real disk; the test framework provides its own.
        fileSystems = lib.mkForce { };
        boot.loader.systemd-boot.enable = lib.mkForce false;

        virtualisation = {
          memorySize = 4096;
          cores = 4;
          writableStore = true;
        };

        # python3 is needed by the test script that verifies message flow.
        # curl is used in openrouter mode to verify outbound internet.
        environment.systemPackages = [
          pkgs.python3
          pkgs.curl
        ];

        # In openrouter mode: switch provider/model and give the VM
        # outbound internet via a second user-mode NIC so it can reach
        # api.openrouter.ai. The first NIC stays on the test driver's
        # vlan for the python harness <-> machine plumbing.
        services.opencrow-local = lib.mkIf useOpenrouter {
          openrouter.enable = true;
          openrouter.apiKeyFile = apiKeyFile;
          defaultModel = openrouterModel;
          extraEnvironment = {
            OPENCROW_PI_PROVIDER = "openrouter";
            OPENCROW_PI_MODEL = openrouterModel;
          };
        };

        # nixosTest's default networking is QEMU user-mode (gateway
        # 10.0.2.2, DNS 10.0.2.3). Enable DHCP and bypass NetworkManager
        # to give the VM outbound internet for api.openrouter.ai. See
        # debug/installer-gui-end-to-end.nix for the same pattern.
        networking = lib.mkIf useOpenrouter {
          useDHCP = lib.mkForce true;
          nameservers = lib.mkForce [ "10.0.2.3" ];
        };
        environment.etc = lib.mkIf useOpenrouter {
          "resolv.conf".text = lib.mkForce "nameserver 10.0.2.3\n";
        };
      };

    testScript =
      { nodes, ... }:
      let
        uid = toString nodes.test-machine.users.users.test.uid;
        modeArg = if useOpenrouter then "openrouter" else "local";
      in
      ''
        import json
        machine.wait_for_unit("multi-user.target")

        ${lib.optionalString useOpenrouter ''
          with subtest("VM has outbound internet (openrouter mode)"):
              machine.wait_until_succeeds(
                  "curl --silent --fail --max-time 10 https://openrouter.ai/api/v1/models > /dev/null",
                  timeout=20,
              )
        ''}

        with subtest("greetd autostarts the niri session"):
            machine.wait_for_unit("greetd.service")
            # pam_systemd starts user@1000.service when greetd opens the session;
            # use wait_until_succeeds because the start job may not be queued yet.
            machine.wait_until_succeeds(
                "systemctl is-active user@${uid}.service",
                timeout=30,
            )

        with subtest("niri.service starts under the user manager"):
            machine.wait_until_succeeds(
                "systemctl --user --machine=test@.host is-active niri.service",
                timeout=30,
            )

        with subtest("niri exposes its Wayland socket"):
            machine.wait_for_file("/run/user/${uid}/wayland-1", timeout=30)

        with subtest("noctalia-shell is running"):
            machine.wait_until_succeeds(
                "systemctl --user --machine=test@.host is-active noctalia-shell.service",
                timeout=30,
            )
            machine.wait_until_succeeds(
                "test -d /run/user/${uid}/quickshell",
                timeout=30,
            )

        with subtest("opencrow-chat plugin is autoloaded"):
            # The plugin symlink must exist in both plugins/ and plugins-autoload/.
            machine.wait_until_succeeds(
                "test -L /home/test/.config/noctalia/plugins/opencrow-chat",
                timeout=30,
            )
            machine.wait_until_succeeds(
                "test -L /home/test/.config/noctalia/plugins-autoload/opencrow-chat",
                timeout=30,
            )
            # plugins.json should show opencrow-chat as auto-enabled.
            machine.wait_until_succeeds(
                "test -f /home/test/.config/noctalia/plugins.json",
                timeout=30,
            )
            # Give noctalia time to scan plugins and save state.
            import time; time.sleep(3)
            plugins = machine.succeed("cat /home/test/.config/noctalia/plugins.json")
            pj = json.loads(plugins)
            states = pj.get("states", {})
            enabled = any(
                s.get("enabled") is True
                for k, s in states.items()
                if "opencrow-chat" in k
            )
            assert enabled, f"opencrow-chat not auto-enabled in plugins.json: {pj}"

        with subtest("opencrow container starts"):
            machine.wait_for_unit("container@opencrow-local.service", timeout=120)
            machine.wait_until_succeeds(
                "systemctl --machine=opencrow-local is-active opencrow.service",
                timeout=60,
            )
            machine.execute(
                "journalctl --machine=opencrow-local -u opencrow.service --no-pager -n 50"
            )

        with subtest("chat socket is accessible"):
            machine.wait_for_file("/run/opencrow-local/chat.sock", timeout=30)
            # Socket symlink for noctalia plugin
            machine.wait_until_succeeds(
                "systemctl --user --machine=test@.host is-active opencrow-socket-link.service",
                timeout=30,
            )
            machine.wait_for_file("/run/user/${uid}/opencrow-chat.sock", timeout=30)

        with subtest("send message and receive reply"):
            machine.copy_from_host("${testChat}", "/tmp/test-chat.py")
            machine.succeed(
                "python3 /tmp/test-chat.py /run/user/${uid}/opencrow-chat.sock ${modeArg}"
            )
      '';
  };
in
if useOpenrouter then
  # __impure grants the build sandbox network access so the VM's
  # user-mode NIC can actually reach api.openrouter.ai. Without this
  # the second NIC is wired up but trapped behind the sandbox.
  baseTest.overrideTestDerivation (_prev: {
    __impure = true;
  })
else
  baseTest
