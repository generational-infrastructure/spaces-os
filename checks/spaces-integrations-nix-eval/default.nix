# Cheap nix-eval contract for the agent-integrations materialiser
# (modules/nixos/spaces-integrations/, docs/agent-integrations-poc-plan.md step 1).
#
# Pins two things:
#   - the wiring: declaring an integration emits a socket-activated, Landlock-
#     confined `--user` service (ExecStartPre lowers the policy, ExecStart execs
#     through pi-landlock-exec), its `.socket`, and a world-readable /etc
#     definition carrying the gateway/panel contract but no command/secret value;
#   - the lowering: running the real spaces-landlock-policy CLI on sample
#     resolved paths yields a deny-by-default landlockconfig granting EXACTLY the
#     StateDirectory (rw), the credentials mount (ro), and the declared egress
#     port — nothing else.
#
# Eval-discipline: the unit's Exec* lines reference pi-landlock-exec; their shape
# is asserted at eval (string match never realizes the Rust build), then stripped
# before export. Only the cheap spaces-landlock-policy bundle (bun + sandbox.ts,
# no pi closure) is realized — the check has to run it.
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  pkgsSelf = inputs.self.packages.${pkgs.stdenv.hostPlatform.system};

  baseModules = [
    {
      nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
      };
      boot.loader.grub.enable = false;
      system.stateVersion = "26.05";
    }
  ];

  mkSystem =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit inputs;
        flake = inputs.self;
      };
      modules = baseModules ++ extra;
    };

  sampleIntegrations = {
    # Networked + secret-bearing: the GitHub demo's posture.
    github = {
      description = "GitHub";
      command = "integration-github-placeholder";
      network = true;
      connectPorts = [ 443 ];
      secrets.token.description = "GitHub personal access token";
      autoRun = [ "get_repo" ];
    };
    # Offline, secretless: must collapse to AF_UNIX only with no credentials.
    notes = {
      description = "Local notes";
      command = "integration-notes-placeholder";
    };
  };

  enabledSystem = mkSystem [
    inputs.self.nixosModules.spaces-integrations
    {
      networking.hostName = "integ-on";
      services.spaces-integrations = {
        enable = true;
        integrations = sampleIntegrations;
      };
    }
  ];

  disabledSystem = mkSystem [
    inputs.self.nixosModules.spaces-integrations
    { networking.hostName = "integ-off"; }
  ];

  ghSvc = enabledSystem.config.systemd.user.services."spaces-integration-github";
  ghSock = enabledSystem.config.systemd.user.sockets."spaces-integration-github";
  notesSvc = enabledSystem.config.systemd.user.services."spaces-integration-notes";

  # Strip the store-path-bearing Exec lines (shape asserted at eval below) so the
  # exported serviceConfig stays free of build deps.
  ghSvcStripped = builtins.removeAttrs ghSvc.serviceConfig [
    "ExecStart"
    "ExecStartPre"
  ];
  notesSvcStripped = builtins.removeAttrs notesSvc.serviceConfig [
    "ExecStart"
    "ExecStartPre"
  ];

  # Reuse lib.nix to obtain the SAME policy spec the unit's ExecStartPre feeds the
  # CLI, so the lowering test exercises the real artifact.
  integLib = import ../../modules/nixos/spaces-integrations/lib.nix { inherit pkgs lib; };
  ghInteg = integLib.mkIntegration {
    name = "github";
    manifest = enabledSystem.config.services.spaces-integrations.integrations.github;
    landlockPolicyCli = "unused-here";
    landlockExec = "unused-here";
  };
  ghDef = ghInteg.definition;
  brokerSvc = enabledSystem.config.systemd.user.services.spaces-integrationd;
in
# ── Exec lines: shape at eval (no realize) ──────────────────────────────────
assert lib.any (lib.hasInfix "/bin/spaces-landlock-policy ") ghSvc.serviceConfig.ExecStartPre;
assert lib.any (lib.hasInfix "--out %t/spaces-integration-github/landlock.json")
  ghSvc.serviceConfig.ExecStartPre;
# File exchange (step 6): the unit creates its shared dir pre-start and declares
# it; the agent session grants itself the SAME path (asserted in the gateway check).
assert lib.any (lib.hasInfix "/bin/mkdir -p %t/spaces-integration-share/github")
  ghSvc.serviceConfig.ExecStartPre;
assert lib.any (lib.hasInfix "SPACES_INTEGRATION_SHARED_DIR=%t/spaces-integration-share/github")
  ghSvc.serviceConfig.Environment;
assert lib.hasInfix "/bin/pi-landlock-exec " ghSvc.serviceConfig.ExecStart;
assert lib.hasInfix "--json %t/spaces-integration-github/landlock.json --"
  ghSvc.serviceConfig.ExecStart;
assert lib.hasInfix "integration-github-placeholder" ghSvc.serviceConfig.ExecStart;
# The definition is the safe contract surface — never the command or a secret value.
assert ghDef.autoRun == [ "get_repo" ];
assert ghDef.network;
assert ghDef ? secrets && ghDef.secrets ? token;
assert !(ghDef ? command);
# ── Broker unit (step 2): user-scoped host+tpm2 secret path, never pure tpm2 ─
assert lib.hasSuffix "/bin/spaces-integrationd" brokerSvc.serviceConfig.ExecStart;
assert brokerSvc.serviceConfig.StateDirectory == "spaces-integrationd";
assert lib.any (lib.hasInfix "--with-key=host+tpm2") brokerSvc.serviceConfig.Environment;
assert lib.any (lib.hasInfix "%t/spaces-integrations.sock") brokerSvc.serviceConfig.Environment;
pkgs.runCommand "spaces-integrations-nix-eval-test"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgsSelf.pi-sessiond.landlockPolicy
    ];
    ghServiceConfig = builtins.toJSON ghSvcStripped;
    notesServiceConfig = builtins.toJSON notesSvcStripped;
    ghSocket = builtins.toJSON ghSock.socketConfig;
    ghDefinition = builtins.toJSON ghDef;
    specFile = ghInteg.policySpecFile;
    disabledHasGithub =
      if (disabledSystem.config.systemd.user.services."spaces-integration-github" or null) == null then
        "no"
      else
        "yes";
    hasEtc =
      if enabledSystem.config.environment.etc ? "spaces-integrations/github.json" then "yes" else "no";
  }
  ''
    set -euo pipefail
    export HOME=$TMPDIR   # bun's transpile cache
    fail() { echo "FAIL: $*" >&2; exit 1; }
    sc()    { jq -e "$1" <<<"$ghServiceConfig"    >/dev/null || fail "github serviceConfig: $1"; }
    notes() { jq -e "$1" <<<"$notesServiceConfig" >/dev/null || fail "notes serviceConfig: $1"; }
    sock()  { jq -e "$1" <<<"$ghSocket"           >/dev/null || fail "github socket: $1"; }
    def()   { jq -e "$1" <<<"$ghDefinition"       >/dev/null || fail "github definition: $1"; }

    # ── 1. github unit shape ────────────────────────────────────────
    sc '.Type == "exec"'
    sc '.StateDirectory == "spaces-integration-github"'
    sc '.RuntimeDirectory == "spaces-integration-github"'
    sc '.LoadCredentialEncrypted == ["token:%S/spaces-integrationd/github/token"]'
    # network = true → IP egress permitted at the family layer (Landlock netPort
    # refines the ports below).
    sc '.RestrictAddressFamilies == "AF_UNIX AF_INET AF_INET6"'
    sc '.NoNewPrivileges == true'
    sc '.RestrictNamespaces == true'
    sc '.ProtectProc == "invisible"'
    # The shared seccomp denylist is subtracted from @system-service.
    sc '.SystemCallFilter | index("@system-service") != null'
    sc 'any(.SystemCallFilter[]; startswith("~ptrace"))'
    sc '.SystemCallErrorNumber == "EPERM"'

    # ── 2. offline integration: no IP egress, no credentials ────────
    notes '.RestrictAddressFamilies == "AF_UNIX"'
    notes '.LoadCredentialEncrypted == []'

    # ── 3. socket-activation endpoint ───────────────────────────────
    sock '.ListenStream == "%t/spaces-integration-github.sock"'

    # ── 4. definition = safe contract (no command, no secret value) ─
    def '.autoRun == ["get_repo"]'
    def '.secrets.token.description | length > 0'
    def 'has("command") | not'
    [ "$hasEtc" = "yes" ] || fail "github definition not wired into /etc"

    # ── 5. disabled / undeclared module generates nothing ───────────
    [ "$disabledHasGithub" = "no" ] || fail "disabled module still declared a github unit"

    # ── 6. the CLI lowers a deny-by-default policy ──────────────────
    # exactly StateDirectory(rw) + credentials(ro) + 443; nothing else.
    policy=$PWD/landlock.json
    env STATE_DIRECTORY=/sample/state CREDENTIALS_DIRECTORY=/sample/cred \
      spaces-landlock-policy --spec "$specFile" --out "$policy"
    jq -e '.abi == 6' "$policy" >/dev/null || fail "policy abi"
    jq -e '.ruleset == [{"scoped":["signal","abstract_unix_socket"]}]' "$policy" >/dev/null \
      || fail "policy IPC scope"
    jq -e '.netPort == [{"allowedAccess":["connect_tcp"],"port":[443]}]' "$policy" >/dev/null \
      || fail "egress not locked to 443"
    jq -e '[.pathBeneath[] | select(.allowedAccess | index("abi.read_write")) | .parent] == [["/sample/state"]]' "$policy" >/dev/null \
      || fail "writable surface != StateDirectory"
    jq -e 'any(.pathBeneath[]; (.parent | index("/sample/cred")) and (.allowedAccess | index("read_file")) and (.allowedAccess | index("write_file") | not))' "$policy" >/dev/null \
      || fail "credentials mount not read-only"
    jq -e '[.pathBeneath[].parent[]] | (index("/sample") == null) and (index("/home") == null)' "$policy" >/dev/null \
      || fail "policy granted an unexpected path"

    # ── 7. file exchange (step 6): when systemd resolves the shared dir, the CLI
    # folds it into the writable surface — the SAME dir the agent session grants
    # itself rw. Unset above (section 6) ⇒ rw is StateDirectory only.
    policy2=$PWD/landlock-shared.json
    env STATE_DIRECTORY=/sample/state CREDENTIALS_DIRECTORY=/sample/cred \
        SPACES_INTEGRATION_SHARED_DIR=/sample/share \
      spaces-landlock-policy --spec "$specFile" --out "$policy2"
    jq -e '([.pathBeneath[] | select(.allowedAccess | index("abi.read_write")) | .parent[]]) as $rw
           | (($rw | index("/sample/state")) != null) and (($rw | index("/sample/share")) != null)' \
      "$policy2" >/dev/null || fail "shared dir not granted rw when SPACES_INTEGRATION_SHARED_DIR set"

    touch "$out"
  ''
