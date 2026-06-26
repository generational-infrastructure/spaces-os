# Focused check: the system (root) executor drops every per-session pi unit to
# the unprivileged `pi-session` uid and chowns the session's dirs to it
# (docs/landlock-sandbox-design.md §14.2). The cheap pi-sessiond-landlock check
# proves the Landlock domain itself in isolation; this pins the *deployment*
# property that walls a session off from root on the always-on server — the
# uid-drop + chown that systemd-run --uid and chownTree perform in system scope
# (a no-op on the desktop user service, where the unit keeps the daemon's uid).
#
# Boots services.pi-sessiond (root daemon; SESSION_USER=pi-session by default),
# drives one full turn against a mock LLM (reusing the remote-session driver) so
# a pi child is spawned and stays live-idle, then asserts: the supervisor runs
# as root; the spawned pi-session-<id>.service runs as the non-root pi-session
# uid; and the session dir + workdir are owned by it.
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
  name = "pi-sessiond-session-uid";
  meta.platforms = [ "x86_64-linux" ];
  node.specialArgs = { inherit inputs; };

  nodes.machine =
    { ... }:
    {
      imports = [ inputs.self.nixosModules.pi-sessiond ];

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
    machine.wait_for_unit("pi-sessiond.service")
    machine.wait_for_open_port(${toString wsPort})

    ws = "ws://127.0.0.1:${toString wsPort}"
    tok = "${token}"

    # The supervisor is the trusted half — it spawns the uid-dropped session
    # units, so it must itself run as root.
    with subtest("supervisor runs as root"):
        pid = machine.succeed("systemctl show -p MainPID --value pi-sessiond.service").strip()
        assert pid != "0", "daemon has no main pid"
        owner = machine.succeed(f"stat -c %u /proc/{pid}").strip()
        assert owner == "0", f"supervisor runs as uid {owner}, expected root"

    # Drive a full turn so a pi child is spawned; it stays live-idle (long idle
    # timeout) after the driver detaches, so its unit + dirs remain inspectable.
    out = machine.succeed(f"${py}/bin/python3 ${driver} {ws} {tok}")
    sid = next(
        line.split("=", 1)[1].strip()
        for line in out.splitlines()
        if line.startswith("SESSION_ID=")
    )

    uid = machine.succeed("id -u pi-session").strip()
    unit = f"pi-session-{sid}.service"

    with subtest("the per-session pi unit runs as the unprivileged pi-session uid"):
        machine.wait_until_succeeds(
            f"systemctl show -p MainPID --value {unit} | grep -qE '^[1-9][0-9]*$'",
            timeout=30,
        )
        spid = machine.succeed(f"systemctl show -p MainPID --value {unit}").strip()
        suid = machine.succeed(f"stat -c %u /proc/{spid}").strip()
        assert suid == uid, f"session runs as uid {suid}, expected pi-session {uid}"
        assert suid != "0", "session must not run as root"

    with subtest("the session's dirs are chowned to pi-session"):
        for d in (
            f"/var/lib/pi-sessiond/sessions/{sid}",
            f"/var/lib/pi-sessiond/workspaces/{sid}",
        ):
            d_owner = machine.succeed(f"stat -c %U {d}").strip()
            assert d_owner == "pi-session", f"{d} owned by {d_owner}, expected pi-session"
  '';
}
