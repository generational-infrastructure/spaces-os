# Full-system VM check for the agent-integrations POC (design §9.5, poc-plan
# step 7). NOT bolted onto test-machine.nix: it boots its own machine with a
# software TPM (swtpm) and two users to exercise the security properties the
# cheap checks can't — the real secret path, the same-uid Landlock wall, the
# cross-user DAC boundary, and the file-exchange round-trip through the REAL
# pi-sessiond gateway + real pi + the spaces-integrations extension.
#
# `alice` provisions and runs everything (linger keeps her --user manager up);
# `bob` is a sibling in the SAME `tss` group, present only to show the wall
# between users is uid DAC + user-scoped credentials, not group membership.
# GitHub is replaced by an in-VM mock; the model by a mock LLM that scripts the
# tool-call chain (get_repo → clone_to_workspace → a native edit → open_pull_request).
#
# Asserts (the §9.5 matrix):
#   1. enable is refused while the secret is unprovisioned;
#   2. at rest only ciphertext (a plaintext grep finds nothing);
#   3. `systemd-creds encrypt --user --uid=self --with-key=host+tpm2` succeeds
#      as the non-root user;
#   4. the running integration decrypts the secret (secret_fingerprint);
#   5. a sibling user (same `tss` group) cannot read the ciphertext or reach the
#      broker socket — cross-user DAC + user-scoped, uid-bound creds;
#   6. the integration authenticates to the mock with the delivered token
#      (Authorization observed server-side);
#   7. file exchange: clone populates the shared workspace, the agent edits it
#      natively, and open_pull_request reflects that edit back — both effects
#      confirm-gated by the gateway (get_repo, autoRun, is not);
#   8. the agent's Landlock domain cannot reach the integration's socket or
#      private runtime state, while the unconfined supervisor (same uid) can,
#      and the grant is selective (the shared workspace stays reachable).
{ pkgs, inputs, ... }:

let
  inherit (pkgs) lib;
  pkgsSelf = inputs.self.packages.${pkgs.stdenv.hostPlatform.system};
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);

  wsPort = 8769;
  llmPort = 8013;
  mockPort = 8771;
  token = "poc-ws-token";
  pat = "ghp_pocSECRET0123456789abcXYZ";

  landlockExec = lib.getExe pkgsSelf.pi-landlock-exec;

  # Point the github integration at the in-VM mock instead of api.github.com. A
  # wrapper (rather than a new module env knob) keeps the integration package
  # and the spaces-integrations contract untouched for the POC; it runs inside
  # the Landlock domain, reachable as a /nix/store path.
  ghWrapper = pkgs.writeShellScript "integration-github-poc" ''
    export SPACES_GITHUB_API_URL="http://127.0.0.1:${toString mockPort}"
    exec ${lib.getExe pkgsSelf.integration-github}
  '';
in
pkgs.testers.runNixOSTest {
  name = "integration-poc-machine";
  meta.platforms = [ "x86_64-linux" ];
  node.specialArgs = { inherit inputs; };

  nodes.machine =
    { ... }:
    {
      imports = [
        inputs.self.nixosModules.pi-sessiond
        inputs.self.nixosModules.spaces-integrations
      ];

      virtualisation = {
        memorySize = 4096;
        cores = 4;
        # swtpm — the user-scoped host+tpm2 credential path needs a TPM.
        tpm.enable = true;
      };

      users.users.alice = {
        isNormalUser = true;
        uid = 1001;
        linger = true;
        extraGroups = [ "tss" ];
      };
      users.users.bob = {
        isNormalUser = true;
        uid = 1002;
        extraGroups = [ "tss" ];
      };

      services.spaces-integrations = {
        enable = true;
        integrations.github = {
          description = "GitHub (POC)";
          command = "${ghWrapper}";
          network = true;
          connectPorts = [ mockPort ];
          secrets.token.description = "GitHub personal access token";
          autoRun = [ "get_repo" ];
        };
      };

      services.pi-sessiond = {
        enable = true;
        host = "127.0.0.1";
        port = wsPort;
        inherit token;
        llmUrl = "http://127.0.0.1:${toString llmPort}";
        defaultModel = "mock-model";
        defaultProvider = "local";
        memory.enable = false;
        # Auto-run the agent's one scripted edit so the file-exchange turn needs
        # no bash confirm — the integration tool approvals are the gated effects
        # under test.
        bashConfirm.allowPatterns = [ "^echo agent-was-here" ];
      };

      systemd.services.mock-llm = {
        description = "Mock OpenAI LLM scripting the integration turn";
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${py}/bin/python3 ${./mock-llm.py} ${toString llmPort}";
      };

      systemd.services.mock-github = {
        description = "Mock GitHub REST API";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          StateDirectory = "mock-github";
          ExecStart = "${pkgs.python3}/bin/python3 ${./mock-github.py} ${toString mockPort} /var/lib/mock-github/requests.jsonl";
        };
      };
    };

  testScript = ''
    import hashlib
    import json

    WS = "ws://127.0.0.1:${toString wsPort}"
    TOKEN = "${token}"
    PAT = "${pat}"
    ALICE_RT = "/run/user/1001"
    SOCK = ALICE_RT + "/spaces-integrations.sock"
    GH_SOCK = ALICE_RT + "/spaces-integration-github.sock"
    PRIVATE = ALICE_RT + "/spaces-integration-github/landlock.json"
    WS_DIR = ALICE_RT + "/spaces-integration-share/github/hello"
    CRED = "/home/alice/.local/state/spaces-integrationd/github/secrets"
    STATE = "/home/alice/.local/state/spaces-integrationd"

    PY = "${py}/bin/python3"
    BROKER = "${./broker.py}"
    MCP = "${./mcp-call.py}"
    WSDRIVE = "${./ws-drive.py}"
    PROBE = "${./probe.py}"
    LL = "${landlockExec}"
    AS_ALICE = f"sudo -u alice env XDG_RUNTIME_DIR={ALICE_RT} HOME=/home/alice "

    def broker(*args):
        return json.loads(machine.succeed(AS_ALICE + f"{PY} {BROKER} {SOCK} " + " ".join(args)))

    start_all()
    machine.wait_for_unit("mock-llm.service")
    machine.wait_for_unit("mock-github.service")
    machine.wait_for_unit("user@1001.service")
    machine.wait_until_succeeds(
        "systemctl --user --machine=alice@.host is-active spaces-integrationd.service",
        timeout=90,
    )
    machine.wait_until_succeeds(
        "systemctl --user --machine=alice@.host is-active pi-sessiond.service",
        timeout=120,
    )
    machine.wait_for_open_port(${toString wsPort})

    with subtest("1. enable is refused while the secret is unprovisioned"):
        ack = broker("enable", "github")
        assert ack["op"] == "error", ack
        lst = broker("list")
        gh = next(i for i in lst["integrations"] if i["name"] == "github")
        assert not gh["enabled"], gh
        # github is single-account (multiProfile off): no profile provisioned yet.
        assert gh["profiles"] == [], gh

    with subtest("3. host+tpm2 user-scoped encrypt succeeds for the non-root user"):
        # (asserted before set-secret so a failure here localises the cause)
        machine.succeed(
            AS_ALICE
            + "sh -c 'echo -n probe | systemd-creds encrypt --user --uid=self "
            + "--with-key=host+tpm2 - - >/dev/null'"
        )

    with subtest("2. set-field seals host+tpm2 ciphertext, no plaintext at rest"):
        assert broker("set-field", "github", "default", "token", PAT)["op"] == "ok"
        machine.succeed(f"test -f {CRED}")
        # the plaintext token must appear nowhere under the broker state dir
        machine.fail(f"grep -rqF '{PAT}' {STATE}")

    with subtest("enable succeeds once the secret is present"):
        assert broker("enable", "github")["op"] == "ok"

    with subtest("4. the running integration decrypts the secret (secret_fingerprint)"):
        # connecting the socket triggers activation (the 'launch'); the unit can
        # only answer if it decrypted $CREDENTIALS_DIRECTORY/token.
        fp = machine.succeed(
            AS_ALICE + f"{PY} {MCP} {GH_SOCK} secret_fingerprint '{{}}'"
        ).strip()
        assert fp == hashlib.sha256(PAT.encode()).hexdigest()[:16], fp

    with subtest("5. a sibling tss user cannot read the ciphertext or reach the socket"):
        machine.fail(f"sudo -u bob test -r {CRED}")
        machine.fail(
            f"sudo -u bob env XDG_RUNTIME_DIR={ALICE_RT} {PY} {BROKER} {SOCK} list"
        )

    # The gateway builds its registry once at startup; restart so it discovers
    # the now-enabled integration before the e2e session.
    machine.succeed("systemctl --user --machine=alice@.host restart pi-sessiond.service")
    machine.wait_for_open_port(${toString wsPort})

    with subtest("6+7. file exchange: clone -> agent edits -> PR, effects confirm-gated"):
        out = machine.succeed(
            f"{PY} {WSDRIVE} {WS} {TOKEN} 'please run the integration demo'"
        )
        sid = next(
            l.split("=", 1)[1].strip() for l in out.splitlines() if l.startswith("SESSION_ID=")
        )
        approved = json.loads(
            next(l.split("=", 1)[1] for l in out.splitlines() if l.startswith("APPROVED="))
        )
        assert "github_clone_to_workspace" in approved, approved
        assert "github_open_pull_request" in approved, approved
        assert "github_get_repo" not in approved, f"autoRun tool must not prompt: {approved}"

        # clone populated the shared workspace; the agent's native edit is there.
        machine.succeed(f"test -f {WS_DIR}/README.md")
        machine.succeed(f"test -f {WS_DIR}/AGENT_EDIT.md")

        recs = [
            json.loads(l)
            for l in machine.succeed("cat /var/lib/mock-github/requests.jsonl").splitlines()
            if l.strip()
        ]
        tarball = [r for r in recs if "/tarball" in r["path"]]
        pulls = [r for r in recs if r["path"].endswith("/pulls") and r["method"] == "POST"]
        assert tarball, "integration never fetched the tarball"
        assert tarball[0]["authorization"] == f"Bearer {PAT}", tarball[0]
        assert pulls, "no pull request was opened"
        assert pulls[0]["authorization"] == f"Bearer {PAT}", pulls[0]
        # the PR carried the agent's edited file back — the shared dir round-trips.
        assert "AGENT_EDIT.md" in (pulls[0]["body"] or {}).get("body", ""), pulls[0]

    with subtest("8. the agent Landlock domain is walled off from the integration"):
        policy = f"/home/alice/.local/state/pi-sessiond/sessions/{sid}/landlock.json"
        machine.succeed(f"test -f {policy}")
        confined = machine.succeed(
            AS_ALICE + f"{LL} --json {policy} -- {PY} {PROBE} {PRIVATE} {WS_DIR}/README.md"
        )
        # Landlock gates filesystem opens (not AF_UNIX connect): the integration's
        # private runtime state is denied, while the granted shared workspace stays
        # reachable — a selective, deny-by-default wall.
        assert "private DENIED" in confined, confined
        assert "shared OK" in confined, confined
        # same uid, unconfined: the supervisor reaches the private state too.
        unconfined = machine.succeed(
            AS_ALICE + f"{PY} {PROBE} {PRIVATE} {WS_DIR}/README.md"
        )
        assert "private OK" in unconfined, unconfined
  '';
}
