# Full-system test: the chat panel multi-homed to TWO executors at once
# (design stage 4). One desktop, two lightweight fake pi-sessiond daemons with
# distinct replies; the panel pins one session to each executor and drives both,
# asserting each session streams from its OWN executor (routing) and never
# leaks the other's reply.
#
# Lightweight executors (no real pi/LLM) — routing is panel-side, so a fake WS
# daemon per executor suffices. x86_64-linux only; stub elsewhere.
{ pkgs, inputs, ... }:

if pkgs.stdenv.hostPlatform.system != "x86_64-linux" then
  pkgs.runCommand "pi-chat-multihome-x86_64-only" { } "mkdir -p $out"
else

  let
    inherit (pkgs) lib;
    token = "multihome-secret";
    portA = 8770;
    portB = 8771;
    replyA = "Hello from ALPHA";
    replyB = "Bonjour depuis BETA";
    py = pkgs.python3.withPackages (ps: [ ps.websockets ]);

    daemonService = port: reply: {
      description = "Fake pi-sessiond executor on ${toString port}";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${py}/bin/python3 ${./fake-daemon.py} ${toString port} ${lib.escapeShellArg reply} ${token}";
        Restart = "on-failure";
      };
    };
  in
  pkgs.testers.runNixOSTest {
    name = "pi-chat-multihome";
    node.specialArgs = { inherit inputs; };

    nodes.desktop =
      { lib, pkgs, ... }:
      {
        imports = [
          inputs.self.nixosModules.spaces
          ../../hosts/test-machine/configuration.nix
          inputs.self.nixosModules.test-support
        ];

        fileSystems = lib.mkForce { };
        boot.loader.systemd-boot.enable = lib.mkForce false;

        virtualisation = {
          memorySize = 4096;
          cores = 4;
          writableStore = true;
        };

        environment.systemPackages = [ pkgs.python3 ];

        # Two executors, no local LLM; new/bootstrap sessions default to alpha.
        services.pi-chat = {
          skills = lib.mkForce { };
          extensions.bash-confirm = false;
          executors = [
            {
              id = "alpha";
              url = "ws://127.0.0.1:${toString portA}";
              token = token;
            }
            {
              id = "beta";
              url = "ws://127.0.0.1:${toString portB}";
              token = token;
            }
          ];
          defaultExecutor = "alpha";
        };
        services.llama-swap.enable = lib.mkForce false;

        systemd.services.fake-exec-alpha = daemonService portA replyA;
        systemd.services.fake-exec-beta = daemonService portB replyB;
      };

    testScript =
      { nodes, ... }:
      let
        uid = toString nodes.desktop.users.users.test.uid;
      in
      ''
        start_all()

        with subtest("both fake executors are up"):
            desktop.wait_for_unit("fake-exec-alpha.service")
            desktop.wait_for_unit("fake-exec-beta.service")
            desktop.wait_for_open_port(${toString portA})
            desktop.wait_for_open_port(${toString portB})

        with subtest("desktop + panel come up"):
            desktop.wait_for_unit("greetd.service")
            desktop.wait_until_succeeds("systemctl is-active user@${uid}.service", timeout=60)
            desktop.wait_until_succeeds(
                "systemctl --user --machine=test@.host is-active niri.service", timeout=60)
            desktop.wait_for_file("/run/user/${uid}/wayland-1", timeout=60)
            desktop.wait_until_succeeds(
                "systemctl --user --machine=test@.host is-active pi-chat.service", timeout=60)

        sudo_env = (
            "sudo -u test "
            "HOME=/home/test "
            "XDG_RUNTIME_DIR=/run/user/${uid} "
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus "
            "WAYLAND_DISPLAY=wayland-1 "
        )

        def ipc(*args):
            return desktop.succeed(
                sudo_env + "quickshell ipc -c pi-chat call pi-chat " + " ".join(args)
            ).strip()

        with subtest("panel IPC target is registered"):
            desktop.wait_until_succeeds(
                sudo_env + "quickshell ipc -c pi-chat show 2>&1 | grep -q pi-chat", timeout=60)

        def dump():
            _, j = desktop.execute(
                "journalctl --user-unit pi-chat.service _UID=${uid} -b --no-pager 2>&1 | tail -120")
            desktop.log("== pi-chat journal ==\n" + j)
            _, cfg = desktop.execute("cat /etc/spaces/pi-chat.json 2>&1")
            desktop.log("== /etc/spaces/pi-chat.json ==\n" + cfg)

        with subtest("each session routes to its own executor"):
            try:
                sid_a = ipc("newSessionOn", "on-alpha", "alpha")
                ipc("send", "hi")
                desktop.wait_until_succeeds(
                    sudo_env
                    + "quickshell ipc -c pi-chat call pi-chat lastAssistantText "
                    + sid_a
                    + " 2>&1 | grep -q ALPHA",
                    timeout=60,
                )

                sid_b = ipc("newSessionOn", "on-beta", "beta")
                ipc("send", "hi")
                desktop.wait_until_succeeds(
                    sudo_env
                    + "quickshell ipc -c pi-chat call pi-chat lastAssistantText "
                    + sid_b
                    + " 2>&1 | grep -q BETA",
                    timeout=60,
                )

                # Routing is exclusive: the alpha session never saw beta's reply.
                a_text = ipc("lastAssistantText", sid_a)
                assert "BETA" not in a_text, f"alpha session leaked beta's reply: {a_text!r}"
            except Exception:
                dump()
                raise

        # Open the panel so the screenshot captures the multi-homed session tabs.
        ipc("selectSession", sid_a)
        ipc("toggle")

        desktop.sleep(2)
        desktop.screenshot("pi-chat-multihome")
      '';
  }
