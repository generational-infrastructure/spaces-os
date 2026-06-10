# Two-VM full-system test: a desktop chat panel drives a session on a REMOTE
# pi-sessiond executor over WebSocket.
#
#   server  — services.pi-sessiond on 0.0.0.0 + a deterministic mock LLM. No
#             desktop; this is the always-on executor.
#   client  — the full test-machine desktop (greetd -> niri -> pi-chat panel),
#             with services.pi-chat.wsUrl pointed at ws://server:8770 and no
#             local executor or LLM.
#
# Boots both, brings the client desktop + panel up, drives a prompt through the
# panel's IPC, and asserts the streamed reply ("Hello, world!") rendered into
# the session — the GUI working against a remote daemon end to end. Captures a
# screenshot of the client panel for visual confirmation.
#
# This is the heavy end-of-unit verification; the cheap per-feature coverage is
# checks/pi-session-ws (headless, no VM).
{ pkgs, inputs, ... }:

let
  token = "remote-pi-chat-secret";
  wsPort = 8770;
  llmPort = 8013;
  mockLlm = ./pi-remote-session/mock-llm.py;
in
pkgs.testers.runNixOSTest {
  name = "pi-chat-remote";
  meta.platforms = [ "x86_64-linux" ];
  node.specialArgs = { inherit inputs; };

  nodes.server =
    { pkgs, ... }:
    {
      imports = [ inputs.self.nixosModules.pi-sessiond ];

      services.pi-sessiond = {
        enable = true;
        executorId = "server";
        host = "0.0.0.0";
        port = wsPort;
        inherit token;
        llmUrl = "http://127.0.0.1:${toString llmPort}";
        defaultModel = "mock-model";
        defaultProvider = "local";
        openFirewall = true;
      };

      # The executor's "llama-swap": a deterministic, offline mock so the
      # daemon's embedded pi streams a fixed "Hello, world!" reply.
      systemd.services.pi-remote-mock-llm = {
        description = "OpenAI-compatible mock LLM for the remote pi-chat test";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${mockLlm} ${toString llmPort}";
          Restart = "on-failure";
        };
      };

      virtualisation = {
        memorySize = 2048;
        cores = 2;
      };
    };

  nodes.client =
    { lib, pkgs, ... }:
    {
      imports = [
        inputs.self.nixosModules.spaces
        ../hosts/test-machine/configuration.nix
        # Software-EGL niri patch + serial console, so niri actually renders
        # an output under QEMU (no GPU) and the screenshot shows the panel.
        inputs.self.nixosModules.test-support
      ];

      # The host pins a real disk; the test framework provides its own.
      fileSystems = lib.mkForce { };
      boot.loader.systemd-boot.enable = lib.mkForce false;

      virtualisation = {
        memorySize = 4096;
        cores = 4;
        writableStore = true;
      };

      environment.systemPackages = [ pkgs.python3 ];

      # Point the panel at the remote executor; no local LLM needed (the
      # server has the mock). The per-user pi-sessiond-local is disabled and
      # the default pinned so the session demonstrably routes to the server.
      services.pi-chat = {
        skills = lib.mkForce { };
        extensions.bash-confirm = false;
        wsUrl = "ws://server:${toString wsPort}";
        wsToken = token;
        localExecutor.enable = false;
        defaultExecutor = "remote";
      };
      services.llama-swap.enable = lib.mkForce false;
    };

  testScript =
    { nodes, ... }:
    let
      uid = toString nodes.client.users.users.test.uid;
    in
    ''
      import json

      start_all()

      with subtest("server executor is up"):
          server.wait_for_unit("pi-remote-mock-llm.service")
          server.wait_for_unit("pi-sessiond.service")
          server.wait_for_open_port(${toString wsPort})

      with subtest("client desktop + panel come up"):
          client.wait_for_unit("multi-user.target")
          client.wait_for_unit("greetd.service")
          client.wait_until_succeeds("systemctl is-active user@${uid}.service", timeout=60)
          client.wait_until_succeeds(
              "systemctl --user --machine=test@.host is-active niri.service", timeout=60)
          client.wait_for_file("/run/user/${uid}/wayland-1", timeout=60)
          client.wait_until_succeeds(
              "systemctl --user --machine=test@.host is-active pi-chat.service", timeout=60)

      sudo_env = (
          "sudo -u test "
          "HOME=/home/test "
          "XDG_RUNTIME_DIR=/run/user/${uid} "
          "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus "
          "WAYLAND_DISPLAY=wayland-1 "
      )

      with subtest("panel IPC target is registered"):
          client.wait_until_succeeds(
              sudo_env + "quickshell ipc -c pi-chat show 2>&1 | grep -q pi-chat", timeout=60)

      def dump_diagnostics():
          _, j = client.execute(
              "journalctl --user-unit pi-chat.service _UID=${uid} -b --no-pager 2>&1 | tail -120")
          client.log("== client pi-chat.service journal ==\n" + j)
          _, qlog = client.execute(
              "tail -120 /run/user/${uid}/quickshell/by-id/*/log.log 2>&1")
          client.log("== client quickshell log ==\n" + qlog)
          _, cfg = client.execute("cat /etc/spaces/pi-chat.json 2>&1")
          client.log("== /etc/spaces/pi-chat.json ==\n" + cfg)
          _, sj = server.execute("journalctl -u pi-sessiond.service -b --no-pager 2>&1 | tail -120")
          server.log("== server pi-sessiond journal ==\n" + sj)

      with subtest("panel drives a session on the REMOTE executor"):
          try:
              raw = client.succeed(
                  sudo_env + "quickshell ipc -c pi-chat call pi-chat listSessions")
              sessions = json.loads(raw or "[]")
              if not sessions:
                  raise Exception(f"shell reported no sessions: {raw!r}")
              sid = next((s["id"] for s in sessions if s.get("active")), sessions[0]["id"])

              # Open the panel so the screenshot shows the conversation.
              client.succeed(sudo_env + "quickshell ipc -c pi-chat call pi-chat toggle")
              client.succeed(
                  sudo_env + "quickshell ipc -c pi-chat call pi-chat send 'hello from the client'")

              client.wait_until_succeeds(
                  sudo_env
                  + "quickshell ipc -c pi-chat call pi-chat lastAssistantText "
                  + sid
                  + " 2>&1 | grep -q 'Hello, world'",
                  timeout=90,
              )

              # The reply renders even if the command-response layer is broken,
              # so assert the panel actually learned its model from the daemon's
              # get_available_models / get_state responses (regression guard:
              # those responses must carry success=true or the panel drops them).
              model_raw = client.succeed(
                  sudo_env + "quickshell ipc -c pi-chat call pi-chat sessionModel " + sid)
              model = json.loads(model_raw or "{}")
              if not model.get("active") or int(model.get("count") or 0) < 1:
                  raise Exception(
                      "panel never learned its model from the daemon "
                      f"(command-response layer rejected): {model_raw!r}")
          except Exception:
              dump_diagnostics()
              raise

      # Let niri compose the panel + streamed reply before capturing.
      client.sleep(3)
      client.screenshot("pi-chat-remote")
    '';
}
