# Focused check: pi-sessiond idle-GC + resident-session ceiling (design §5.1).
#
# Two independent single-purpose executors (no cross-node traffic; each drives
# itself over localhost), because one daemon carries one idle-timeout/ceiling:
#   gc  — short idle timeout, unlimited ceiling: a detached (live-idle) session
#         is stopped after the timeout, then resurrected on re-attach.
#   cap — long idle timeout, ceiling = 1: creating a second session evicts the
#         least-recently-active idle one, which is then resurrected on attach.
#
# Both lean on cold respawn-on-attach: GC/eviction only ever dispose a live-idle
# session, so the committed jsonl is intact and the SDK SessionManager reloads it.
# Reuses the remote-session driver (create/drive/detach + `resume`) and mock LLM.
#
# x86_64-linux only: runNixOSTest needs a kvm + nixos-test builder; other
# systems get a trivial stub so `nix flake check` stays green.
{ pkgs, inputs, ... }:

if pkgs.stdenv.hostPlatform.system != "x86_64-linux" then
  pkgs.runCommand "pi-sessiond-lifecycle-x86_64-only" { } "mkdir -p $out"
else

  let
    token = "lifecycle-test-secret";
    wsPort = 8770;
    llmPort = 8013;

    driver = ../pi-remote-session/driver.py;
    registryDriver = ../pi-remote-session/registry-driver.py;
    mockLlm = ../pi-remote-session/mock-llm.py;
    py = pkgs.python3.withPackages (ps: [ ps.websockets ]);

    executorNode =
      { idleTimeoutMs, maxLive }:
      { ... }:
      {
        imports = [ inputs.self.nixosModules.pi-sessiond ];

        services.pi-sessiond = {
          enable = true;
          host = "127.0.0.1";
          port = wsPort;
          token = token;
          llmUrl = "http://127.0.0.1:${toString llmPort}";
          defaultModel = "mock-model";
          defaultProvider = "local";
          inherit idleTimeoutMs maxLive;
        };

        # Deterministic offline LLM so the spawned pi streams a fixed reply.
        systemd.services.pi-lifecycle-mock-llm = {
          description = "OpenAI-compatible mock LLM for the lifecycle test";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = "${pkgs.python3}/bin/python3 ${mockLlm} ${toString llmPort}";
            Restart = "on-failure";
          };
        };

        virtualisation = {
          memorySize = 3072;
          cores = 2;
        };
      };
  in
  pkgs.testers.runNixOSTest {
    name = "pi-sessiond-lifecycle";
    node.specialArgs = { inherit inputs; };

    nodes.gc = executorNode {
      idleTimeoutMs = 2500;
      maxLive = 0;
    };
    nodes.cap = executorNode {
      idleTimeoutMs = 1800000;
      maxLive = 1;
    };

    testScript = ''
      start_all()

      ws = "ws://127.0.0.1:${toString wsPort}"
      tok = "${token}"


      def drive(node):
          """Create + drive + detach a session on `node`; return its id."""
          out = node.succeed(f"${py}/bin/python3 ${driver} {ws} {tok}")
          for line in out.splitlines():
              if line.startswith("SESSION_ID="):
                  return line.split("=", 1)[1].strip()
          raise Exception(f"driver reported no SESSION_ID: {out!r}")


      def resume(node, sid):
          node.succeed(f"${py}/bin/python3 ${driver} resume {ws} {tok} {sid}")

      def expect_cold(node, sid):
          # idle-GC / eviction disposes the in-process session; it then reports
          # `cold` in the registry, resurrectable from the committed jsonl.
          node.wait_until_succeeds(
              f"${py}/bin/python3 ${registryDriver} expect-cold {ws} {tok} {sid}",
              timeout=30,
          )

      for node in (gc, cap):
          node.wait_for_unit("pi-lifecycle-mock-llm.service")
          node.wait_for_unit("pi-sessiond.service")
          node.wait_for_open_port(${toString wsPort})

      with subtest("idle-GC disposes a detached session; attach resurrects it"):
          sid = drive(gc)
          # The driver exited (no clients): idle-GC disposes the session on its
          # own after the timeout (we never touch it), then reports it cold.
          expect_cold(gc, sid)
          # Cold attach reloads the committed history via the SDK SessionManager
          # (the resume driver asserts get_state messageCount >= 2).
          resume(gc, sid)

      with subtest("ceiling evicts the idle LRU session; attach resurrects it"):
          first = drive(cap)
          # ceiling = 1: creating a second session evicts `first` (idle LRU).
          drive(cap)
          expect_cold(cap, first)
          # The evicted session is cold, not lost: attach resurrects it.
          resume(cap, first)
    '';
  }
