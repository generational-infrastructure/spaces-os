# Focused check: each session gets a private TMPDIR under its session-dir grant,
# and the host's shared /tmp stays denied (docs/landlock-sandbox-design.md §5.1,
# the sessions/<id> row). Without this, a tool that ignores $TMPDIR and
# writes /tmp/... would EACCES against the deny-by-default allowlist.
#
# Boots services.pi-sessiond, drives one turn against a mock LLM so a pi child is
# spawned and stays live-idle, then asserts:
#   - the child's env carries TMPDIR=<sessions/<id>/tmp> (the main.ts wiring), and
#     that dir exists;
#   - replaying the session's *real* emitted landlock.json through the launcher,
#     a write into the private TMPDIR succeeds while a write to the host /tmp is
#     denied — the contract the feature delivers, on the policy actually shipped.
{ pkgs, inputs, ... }:

let
  token = "session-tmpdir-test-secret";
  wsPort = 8773;
  llmPort = 8015;

  landlock = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-landlock-exec;
  driver = ../pi-remote-session/driver.py;
  mockLlm = ../pi-remote-session/mock-llm.py;
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);
in
pkgs.testers.runNixOSTest {
  name = "pi-sessiond-session-tmpdir";
  meta.platforms = [ "x86_64-linux" ];
  node.specialArgs = { inherit inputs; };

  nodes.machine =
    { ... }:
    {
      imports = [ inputs.self.nixosModules.pi-sessiond ];

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
        # Keep the live-idle session up long enough to inspect it.
        idleTimeoutMs = 1800000;
        memory.enable = false;
      };

      systemd.services.pi-tmpdir-mock-llm = {
        description = "OpenAI-compatible mock LLM for the session-tmpdir test";
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
    machine.wait_for_unit("pi-tmpdir-mock-llm.service")
    machine.wait_for_unit("user@1001.service")
    machine.wait_until_succeeds(
        "systemctl --user --machine=agent@.host is-active pi-sessiond.service", timeout=60)
    machine.wait_for_open_port(${toString wsPort})

    ws = "ws://127.0.0.1:${toString wsPort}"
    tok = "${token}"

    out = machine.succeed(f"${py}/bin/python3 ${driver} {ws} {tok}")
    sid = next(
        line.split("=", 1)[1].strip()
        for line in out.splitlines()
        if line.startswith("SESSION_ID=")
    )

    session_dir = f"/home/agent/.local/state/pi-sessiond/sessions/{sid}"
    tmp_dir = f"{session_dir}/tmp"
    policy = f"{session_dir}/landlock.json"
    ll = f"${landlock}/bin/pi-landlock-exec --json {policy} --"

    with subtest("the child's TMPDIR is the private session scratch dir"):
        unit = f"pi-session-{sid}.service"
        show = "systemctl --user --machine=agent@.host show -p MainPID --value"
        machine.wait_until_succeeds(
            f"{show} {unit} | grep -qE '^[1-9][0-9]*$'",
            timeout=30,
        )
        spid = machine.succeed(f"{show} {unit}").strip()
        environ = machine.succeed(f"tr '\\0' '\\n' < /proc/{spid}/environ")
        assert f"TMPDIR={tmp_dir}" in environ.splitlines(), \
            f"child TMPDIR is not {tmp_dir}; environ was:\n{environ}"
        machine.succeed(f"test -d {tmp_dir}")

    with subtest("the emitted policy grants the private TMPDIR but denies host /tmp"):
        # Replay the session's own landlock.json through the launcher: Landlock is
        # uid-independent, so even root-under-the-domain obeys the allowlist.
        machine.succeed(f"{ll} ${pkgs.bash}/bin/bash -c 'echo ok > {tmp_dir}/probe'")
        machine.succeed(f"test \"$(cat {tmp_dir}/probe)\" = ok")
        machine.fail(f"{ll} ${pkgs.bash}/bin/bash -c ': > /tmp/escape-{sid}'")
        machine.succeed(f"test ! -e /tmp/escape-{sid}")
  '';
}
