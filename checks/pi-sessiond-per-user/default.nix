# Focused check: the per-user `--user` executor runs the supervisor AND every
# per-session pi unit as the SAME unprivileged executor uid — no root daemon,
# no uid drop, no chown (docs/pi-sessiond-per-user-refactor.md). The cheap
# pi-sessiond-landlock check proves the Landlock domain in isolation; this pins
# the *deployment* property: a session is walled off and runs as the user, with
# nothing running as root.
#
# Boots the per-user executor under a linger-enabled `agent` account, drives one
# full turn against a mock LLM (reusing the remote-session driver) so a pi child
# is spawned and stays live-idle, then asserts: the supervisor runs as agent
# (not root); the spawned pi-session-<id> user unit runs as the same uid; and the
# session dir + workdir are owned by agent.
{ pkgs, inputs, ... }:

let
  token = "session-uid-test-secret";
  wsPort = 8772;
  llmPort = 8014;

  driver = ../pi-remote-session/driver.py;
  mockLlm = ../pi-remote-session/mock-llm.py;
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);
in
pkgs.testers.runNixOSTest {
  name = "pi-sessiond-per-user";
  meta.platforms = [ "x86_64-linux" ];
  node.specialArgs = { inherit inputs; };

  nodes.machine =
    { ... }:
    {
      imports = [ inputs.self.nixosModules.pi-sessiond ];

      # A real linger-enabled account runs the per-user --user executor; every
      # session child runs as that same uid (no root daemon, no uid drop).
      users.users.agent = {
        isNormalUser = true;
        uid = 1001;
        linger = true;
      };

      services.pi-sessiond = {
        enable = true;
        host = "127.0.0.1";
        port = wsPort;
        inherit token;
        llmUrl = "http://127.0.0.1:${toString llmPort}";
        defaultModel = "mock-model";
        defaultProvider = "local";
        # Keep the live-idle session up long enough to inspect its unit + dirs.
        idleTimeoutMs = 1800000;
        memory.enable = false;
      };

      # Deterministic offline LLM so the spawned pi streams a fixed reply.
      systemd.services.pi-uid-mock-llm = {
        description = "OpenAI-compatible mock LLM for the session-uid test";
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

  testScript = ''
    start_all()
    machine.wait_for_unit("pi-uid-mock-llm.service")
    machine.wait_for_unit("user@1001.service")
    machine.wait_until_succeeds(
        "systemctl --user --machine=agent@.host is-active pi-sessiond.service", timeout=60)
    machine.wait_for_open_port(${toString wsPort})

    ws = "ws://127.0.0.1:${toString wsPort}"
    tok = "${token}"

    # No root daemon: the supervisor runs as the unprivileged executor user.
    with subtest("supervisor runs as the executor user, not root"):
        pid = machine.succeed(
            "systemctl --user --machine=agent@.host show -p MainPID --value pi-sessiond.service"
        ).strip()
        assert pid != "0", "daemon has no main pid"
        owner = machine.succeed(f"stat -c %u /proc/{pid}").strip()
        assert owner != "0", f"supervisor must not run as root (uid {owner})"

    # Drive a full turn so a pi child is spawned; it stays live-idle (long idle
    # timeout) after the driver detaches, so its unit + dirs remain inspectable.
    out = machine.succeed(f"${py}/bin/python3 ${driver} {ws} {tok}")
    sid = next(
        line.split("=", 1)[1].strip()
        for line in out.splitlines()
        if line.startswith("SESSION_ID=")
    )

    uid = machine.succeed("id -u agent").strip()
    unit = f"pi-session-{sid}.service"

    with subtest("the per-session pi unit runs as the same executor uid"):
        show = "systemctl --user --machine=agent@.host show -p MainPID --value"
        machine.wait_until_succeeds(
            f"{show} {unit} | grep -qE '^[1-9][0-9]*$'",
            timeout=30,
        )
        spid = machine.succeed(f"{show} {unit}").strip()
        suid = machine.succeed(f"stat -c %u /proc/{spid}").strip()
        assert suid == uid, f"session runs as uid {suid}, expected agent {uid}"
        assert suid != "0", "session must not run as root"

    with subtest("the session's dirs are owned by the executor user"):
        for d in (
            f"/home/agent/.local/state/pi-sessiond/sessions/{sid}",
            f"/home/agent/.local/state/pi-sessiond/workspaces/{sid}",
        ):
            d_owner = machine.succeed(f"stat -c %U {d}").strip()
            assert d_owner == "agent", f"{d} owned by {d_owner}, expected agent"
  '';
}
