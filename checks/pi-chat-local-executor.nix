# Full-system test: a desktop that hosts its OWN pi-sessiond executor on
# localhost and drives the chat panel through it (stage-1 deploy, design §14).
#
# One node: the full test-machine desktop (greetd -> niri -> pi-chat) PLUS
# services.pi-sessiond bound on 127.0.0.1 and a deterministic mock LLM, with
# services.pi-chat.wsUrl pointed at ws://127.0.0.1:8770. Proves a desktop can
# self-host the executor (daemon + panel coexisting on one machine over loopback
# WS) end to end — the sandboxed `pi --mode rpc` path a desktop uses once it
# stops spawning pi from the panel directly.
#
# This keeps the dual transport: the panel only takes the WS path because
# wsUrl is set here; shipping desktops still default to the local Process path
# (it carries skill-config / side-channels the daemon path doesn't yet).
#
# Heavy end-of-unit verification; the cheap WS coverage is checks/pi-session-ws.
# x86_64-linux only (runNixOSTest needs kvm + nixos-test); stub elsewhere.
{ pkgs, inputs, ... }:

if pkgs.stdenv.hostPlatform.system != "x86_64-linux" then
  pkgs.runCommand "pi-chat-local-executor-x86_64-only" { } "mkdir -p $out"
else

  let
    inherit (pkgs) lib;
    token = "local-executor-secret";
    wsPort = 8770;
    llmPort = 8013;
    mockLlm = ./pi-remote-session/mock-llm.py;
  in
  pkgs.testers.runNixOSTest {
    name = "pi-chat-local-executor";
    node.specialArgs = { inherit inputs; };

    nodes.desktop =
      { lib, pkgs, ... }:
      {
        imports = [
          inputs.self.nixosModules.spaces
          ../hosts/test-machine/configuration.nix
          # Software-EGL niri patch + serial console so niri renders under QEMU.
          inputs.self.nixosModules.test-support
          inputs.self.nixosModules.pi-sessiond
        ];

        # The host pins a real disk; the test framework provides its own.
        fileSystems = lib.mkForce { };
        boot.loader.systemd-boot.enable = lib.mkForce false;

        virtualisation = {
          memorySize = 6144;
          cores = 4;
          writableStore = true;
        };

        environment.systemPackages = [ pkgs.python3 ];

        # The desktop hosts its own executor on loopback...
        services.pi-sessiond = {
          enable = true;
          host = "127.0.0.1";
          port = wsPort;
          token = token;
          llmUrl = "http://127.0.0.1:${toString llmPort}";
          defaultModel = "mock-model";
          defaultProvider = "local";
        };

        # ...and the panel attaches to it instead of spawning pi locally.
        services.pi-chat = {
          skills = lib.mkForce { };
          extensions.bash-confirm = false;
          wsUrl = "ws://127.0.0.1:${toString wsPort}";
          wsToken = token;
        };

        # Deterministic offline LLM (no real llama-swap / GPU).
        services.llama-swap.enable = lib.mkForce false;
        systemd.services.pi-local-mock-llm = {
          description = "OpenAI-compatible mock LLM for the local-executor test";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = "${pkgs.python3}/bin/python3 ${mockLlm} ${toString llmPort}";
            Restart = "on-failure";
          };
        };
      };

    testScript =
      { nodes, ... }:
      let
        uid = toString nodes.desktop.users.users.test.uid;
      in
      ''
        import json

        start_all()

        with subtest("the desktop's own executor is up"):
            desktop.wait_for_unit("pi-local-mock-llm.service")
            desktop.wait_for_unit("pi-sessiond.service")
            desktop.wait_for_open_port(${toString wsPort})

        with subtest("desktop + panel come up"):
            desktop.wait_for_unit("multi-user.target")
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

        with subtest("panel IPC target is registered"):
            desktop.wait_until_succeeds(
                sudo_env + "quickshell ipc -c pi-chat show 2>&1 | grep -q pi-chat", timeout=60)

        def dump_diagnostics():
            _, j = desktop.execute(
                "journalctl --user-unit pi-chat.service _UID=${uid} -b --no-pager 2>&1 | tail -120")
            desktop.log("== pi-chat.service journal ==\n" + j)
            _, sj = desktop.execute(
                "journalctl -u pi-sessiond.service -b --no-pager 2>&1 | tail -120")
            desktop.log("== pi-sessiond journal ==\n" + sj)
            _, cfg = desktop.execute("cat /etc/spaces/pi-chat.json 2>&1")
            desktop.log("== /etc/spaces/pi-chat.json ==\n" + cfg)

        with subtest("panel drives a session on the LOCAL executor"):
            try:
                raw = desktop.succeed(
                    sudo_env + "quickshell ipc -c pi-chat call pi-chat listSessions")
                sessions = json.loads(raw or "[]")
                if not sessions:
                    raise Exception(f"shell reported no sessions: {raw!r}")
                sid = next((s["id"] for s in sessions if s.get("active")), sessions[0]["id"])

                # Open the panel so the screenshot shows the conversation.
                desktop.succeed(sudo_env + "quickshell ipc -c pi-chat call pi-chat toggle")
                desktop.succeed(
                    sudo_env + "quickshell ipc -c pi-chat call pi-chat send 'hello from the desktop'")

                desktop.wait_until_succeeds(
                    sudo_env
                    + "quickshell ipc -c pi-chat call pi-chat lastAssistantText "
                    + sid
                    + " 2>&1 | grep -q 'Hello, world'",
                    timeout=90,
                )
            except Exception:
                dump_diagnostics()
                raise

        # Let niri compose the panel + streamed reply before capturing.
        desktop.sleep(3)
        desktop.screenshot("pi-chat-local-executor")
      '';
  }
