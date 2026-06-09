# Multi-VM check: a chat client opens and drives a pi session on a *remote*
# executor.
#
# Two nodes, mirroring docs/remote-pi-design.md's topology (a client machine
# attaching to the always-on server executor):
#
#   server  — runs `services.pi-sessiond` bound on 0.0.0.0 (the remote
#             executor), backed by a deterministic mock llama-swap so the
#             in-process pi (embedded SDK) replies offline with "Hello, world!".
#   client  — no executor of its own; reaches the server over the test
#             network and speaks the §12 WebSocket envelope protocol.
#
# The client driver asserts the cross-machine contract end to end:
#   hello{token} -> welcome · create_session -> attached · command{prompt}
#   -> a stream of event{pi event} envelopes (>=2 text_delta) ending in
#   agent_end, concatenating to the mock reply.
#
# RED until the real pi-sessiond exists: the placeholder daemon only opens the
# port, so the WebSocket handshake fails and the "drive a session" subtest
# fails — after both VMs boot and the client reaches the server, proving the
# two-node path. The earlier subtests (service up, port open) pass.
{ pkgs, inputs, ... }:

let
  token = "remote-pi-test-secret";
  wsPort = 8770;
  llmPort = 8013;

  driver = ./driver.py;
  registryDriver = ./registry-driver.py;
  mockLlm = ./mock-llm.py;
  clientPython = pkgs.python3.withPackages (ps: [ ps.websockets ]);
in
pkgs.testers.runNixOSTest {
  name = "pi-remote-session";
  meta.platforms = [ "x86_64-linux" ];
  node.specialArgs = { inherit inputs; };

  nodes.server =
    { lib, pkgs, ... }:
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
        openrouter = {
          enable = true;
          apiKeyFile = pkgs.writeText "or-test-key" "sk-or-dummy-test";
        };
      };

      # This executor's "llama-swap": a deterministic, offline mock so the
      # embedded pi streams a fixed reply instead of doing real inference.
      systemd.services.pi-remote-mock-llm = {
        description = "OpenAI-compatible mock LLM for the remote-pi session test";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${mockLlm} ${toString llmPort}";
          Restart = "on-failure";
        };
      };

      virtualisation = {
        memorySize = 4096;
        cores = 4;
      };
    };

  nodes.client = _: {
    virtualisation = {
      memorySize = 1024;
      cores = 1;
    };
  };

  testScript = ''
    import json

    start_all()

    with subtest("server executor comes up and listens"):
        server.wait_for_unit("pi-remote-mock-llm.service")
        server.wait_for_unit("pi-sessiond.service")
        server.wait_for_open_port(${toString wsPort})

    client.wait_for_unit("multi-user.target")

    with subtest("client opens and drives a session on the server executor"):
        out = client.succeed(
            "${clientPython}/bin/python3 ${driver} "
            + "ws://server:${toString wsPort} ${token} server"
        )

    session_id = next(
        (
            line.split("=", 1)[1].strip()
            for line in out.splitlines()
            if line.startswith("SESSION_ID=")
        ),
        "",
    )
    assert session_id, f"driver did not report a SESSION_ID: {out!r}"

    with subtest("session is persisted to disk as jsonl"):
        server.wait_until_succeeds(
            "find /var/lib/pi-sessiond/sessions -name '*.jsonl' | grep -q .",
            timeout=15,
        )


    with subtest("two clients mirror one session"):
        client.succeed(
            "${clientPython}/bin/python3 ${registryDriver} mirror "
            + "ws://server:${toString wsPort} ${token}"
        )

    with subtest("list_sessions reports sessions on the executor"):
        listed = json.loads(
            client.succeed(
                "${clientPython}/bin/python3 ${registryDriver} list "
                + "ws://server:${toString wsPort} ${token}"
            )
        )
        assert listed, f"registry is empty: {listed!r}"
        for s in listed:
            assert s["executor"] == "server", f"wrong executor: {s}"
            assert s["state"] in ("cold", "live-idle", "live-busy", "parked"), s
            assert "id" in s and "name" in s and "updated" in s, s
        assert any(s["id"] == session_id for s in listed), (
            f"resumed session {session_id} missing from registry: {listed}")

    with subtest("a cold session resumes after a full daemon restart"):
        # Restarting the daemon drops every in-process AgentSession; the
        # session is cold on disk (session.jsonl) and the SDK SessionManager
        # reloads it on the next attach.
        server.systemctl("restart pi-sessiond.service")
        server.wait_for_open_port(${toString wsPort})
        client.succeed(
            "${clientPython}/bin/python3 ${driver} resume "
            + f"ws://server:${toString wsPort} ${token} {session_id}"
        )

    with subtest("get_available_models surfaces the OpenRouter catalog"):
        got = client.succeed(
            "${clientPython}/bin/python3 ${driver} models "
            + "ws://server:${toString wsPort} ${token}"
        )
        n = int(next(
            (line.split("=", 1)[1] for line in got.splitlines()
             if line.startswith("OPENROUTER_MODELS=")),
            "0",
        ))
        assert n > 0, f"no OpenRouter models registered: {got!r}"
  '';
}
