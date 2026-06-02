# Focused check: pi-sessiond idle-GC + subprocess ceiling (design §5.1, §397).
#
# Two independent single-purpose executors (no cross-node traffic; each drives
# itself over localhost), because one daemon carries one idle-timeout/ceiling:
#   gc  — short idle timeout, unlimited ceiling: a detached (live-idle) session
#         is stopped after the timeout, then resurrected on re-attach.
#   cap — long idle timeout, ceiling = 1: creating a second session evicts the
#         least-recently-active idle one, which is then resurrected on attach.
#
# Both lean on cold respawn-on-attach: GC/eviction only ever stop a live-idle
# session, so the committed jsonl is intact and `pi --continue` restores it.
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


      def unit(sid):
          return f"pi-sessiond-{sid}.service"


      def resume(node, sid):
          node.succeed(f"${py}/bin/python3 ${driver} resume {ws} {tok} {sid}")


      for node in (gc, cap):
          node.wait_for_unit("pi-lifecycle-mock-llm.service")
          node.wait_for_unit("pi-sessiond.service")
          node.wait_for_open_port(${toString wsPort})

      with subtest("idle-GC stops a detached session; attach resurrects it"):
          sid = drive(gc)
          # The driver has exited, so the session has no clients: idle-GC must
          # stop its subprocess on its own (we never kill it here).
          gc.wait_until_fails(f"systemctl is-active {unit(sid)}", timeout=30)
          # Cold attach respawns `pi --continue` with the committed history
          # (the resume driver asserts get_state messageCount >= 2).
          resume(gc, sid)

      with subtest("ceiling evicts the idle LRU session; attach resurrects it"):
          first = drive(cap)
          cap.wait_for_unit(unit(first))
          # ceiling = 1: creating a second session must evict `first` (idle LRU).
          second = drive(cap)
          cap.wait_for_unit(unit(second))
          cap.wait_until_fails(f"systemctl is-active {unit(first)}", timeout=30)
          # The evicted session is cold, not lost: attach resurrects it.
          resume(cap, first)
    '';
  }
