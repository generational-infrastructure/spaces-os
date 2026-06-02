# Multi-VM check: a chat client opens and drives a pi session on a *remote*
# executor.
#
# Two nodes, mirroring docs/remote-pi-design.md's topology (a client machine
# attaching to the always-on server executor):
#
#   server  — runs `services.pi-sessiond` bound on 0.0.0.0 (the remote
#             executor), backed by a deterministic mock llama-swap so the
#             spawned `pi --mode rpc` replies offline with "Hello, world!".
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
#
# x86_64-linux only: pkgs.testers.runNixOSTest needs a builder advertising
# `kvm + nixos-test`. Other systems get a trivial stub so `nix flake check`
# stays green.
{ pkgs, inputs, ... }:

if pkgs.stdenv.hostPlatform.system != "x86_64-linux" then
  pkgs.runCommand "pi-remote-session-x86_64-only" { } "mkdir -p $out"
else

  let
    token = "remote-pi-test-secret";
    wsPort = 8770;
    llmPort = 8013;

    driver = ./driver.py;
    mockLlm = ./mock-llm.py;
    clientPython = pkgs.python3.withPackages (ps: [ ps.websockets ]);
  in
  pkgs.testers.runNixOSTest {
    name = "pi-remote-session";
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
          token = token;
          llmUrl = "http://127.0.0.1:${toString llmPort}";
          defaultModel = "mock-model";
          defaultProvider = "local";
          openFirewall = true;
        };

        # This executor's "llama-swap": a deterministic, offline mock so the
        # pi subprocess streams a fixed reply instead of doing real inference.
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

    nodes.client =
      { ... }:
      {
        virtualisation = {
          memorySize = 1024;
          cores = 1;
        };
      };

    testScript = ''
      start_all()

      with subtest("server executor comes up and listens"):
          server.wait_for_unit("pi-remote-mock-llm.service")
          server.wait_for_unit("pi-sessiond.service")
          server.wait_for_open_port(${toString wsPort})

      client.wait_for_unit("multi-user.target")

      with subtest("client opens and drives a session on the server executor"):
          client.succeed(
              "${clientPython}/bin/python3 ${driver} "
              + "ws://server:${toString wsPort} ${token} server"
          )
    '';
  }
