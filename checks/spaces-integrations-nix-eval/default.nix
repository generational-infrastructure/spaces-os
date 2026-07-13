# Cheap nix-eval contract for the agent-integrations materialiser
# (modules/nixos/spaces-integrations/, docs/agent-integrations-poc-plan.md step 1).
#
# Pins two things:
#   - the wiring: declaring an integration emits a socket-activated, Landlock-
#     confined `--user` service (ExecStartPre lowers the policy, ExecStart execs
#     through landlock-exec), its `.socket`, and a world-readable /etc
#     definition carrying the gateway/panel contract but no command/secret value;
#   - the lowering: running the real spaces-landlock-policy CLI on sample
#     resolved paths yields a deny-by-default landlockconfig granting EXACTLY the
#     StateDirectory + private tmpfs (rw), the credentials mount (ro), and the
#     declared egress/bind ports — nothing else.
#
# Eval-discipline: the unit's Exec* lines reference landlock-exec; their shape
# is asserted at eval (string match never realizes the Rust build), then stripped
# before export. Only the cheap spaces-landlock-policy bundle (bun + sandbox.ts,
# no pi closure) is realized — the check has to run it.
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  pkgsSelf = inputs.self.packages.${pkgs.stdenv.hostPlatform.system};

  mkSystem =
    extra:
    inputs.self.lib.mkEvalSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = extra;
    };

  sampleIntegrations = {
    # Networked + secret-bearing: the GitHub demo's posture.
    github = {
      description = "GitHub";
      command = "integration-github-placeholder";
      network = true;
      connectPorts = [ 443 ];
      multiProfile = true;
      config.owner.description = "Default owner/org";
      secrets.token.description = "GitHub personal access token";
      autoRun = [ "get_repo" ];
    };
    # Offline, secretless: must collapse to AF_UNIX only with no credentials.
    notes = {
      description = "Local notes";
      command = "integration-notes-placeholder";
    };
    # extraPaths (step 2): a rw daemon-socket dir + an ro attachments dir folded
    # into the Landlock policy. Offline (network defaults false), like signal.
    withpaths = {
      description = "Extra-paths demo";
      command = "integration-withpaths-placeholder";
      extraPaths = [
        {
          source = "/run/user/1000/signal-cli";
          mode = "rw";
        }
        {
          source = "/home/x/.local/share/signal-cli/attachments";
          mode = "ro";
        }
      ];
    };
    # bindPorts (proton-mail groundwork): a listening bridge grants bind_tcp on
    # its local IMAP/SMTP ports. A synthetic name (not a defaults.nix integration)
    # so it never merges with the real `mail` manifest. Networked so the AF_INET
    # family gate is open; no connectPorts, so the bind rule is the only netPort.
    bindports = {
      description = "Bind-ports demo";
      command = "integration-bindports-placeholder";
      network = true;
      bindPorts = [
        1143
        1025
      ];
    };
    # Confined extraService (proton-mail groundwork): a backing vendor daemon
    # attached to a Landlock policy + wrapped in landlock-exec, plus setupPark.
    # Synthetic name so it never merges with the real `proton`/`mail` manifests.
    protonlike = {
      description = "Proton-like bridge demo";
      command = "integration-protonlike-placeholder";
      network = true;
      connectPorts = [
        443
        1143
        1025
      ];
      autoRun = [ "envelope_list" ];
      environment.SPACES_PROTON_BRIDGE_STATE = "%h/.local/state/protonmail-bridge";
      extraPaths = [
        {
          source = "%h/.local/state/protonmail-bridge";
          mode = "rw";
        }
      ];
      setup = "integration-protonlike-setup-placeholder";
      setupPark = [ "spaces-protonlike-bridge.service" ];
      extraServices = [
        {
          name = "spaces-protonlike-bridge.service";
          command = "protonmail-bridge-placeholder --noninteractive";
          description = "Proton-like Bridge daemon";
          network = true;
          connectPorts = [ 443 ];
          bindPorts = [
            1143
            1025
          ];
          extraPaths = [
            {
              source = "%h/.local/state/protonmail-bridge";
              mode = "rw";
            }
          ];
          environment.SPACES_PROTON_BRIDGE_STATE = "%h/.local/state/protonmail-bridge";
          unitConfig.ConditionPathExists = "%h/.local/state/protonmail-bridge/config/protonmail/bridge-v3/vault.enc";
          restart = true;
        }
      ];
    };
    # Bare-string extraService: today's exact behavior — lifecycle only, the
    # daemon is owned/run by another module, NO confined unit is generated.
    barehost = {
      description = "Bare extraServices demo";
      command = "integration-barehost-placeholder";
      extraServices = [ "spaces-external-daemon.service" ];
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
  integLib = import ../../modules/nixos/spaces-integrations/lib.nix {
    inherit pkgs lib;
    inherit (inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond) seccompDenylist;
  };
  ghInteg = integLib.mkIntegration {
    name = "github";
    manifest = enabledSystem.config.services.spaces-integrations.integrations.github;
    landlockPolicyCli = "unused-here";
    landlockExec = "unused-here";
  };
  ghDef = ghInteg.definition;
  wpInteg = integLib.mkIntegration {
    name = "withpaths";
    manifest = enabledSystem.config.services.spaces-integrations.integrations.withpaths;
    landlockPolicyCli = "unused-here";
    landlockExec = "unused-here";
  };
  bindportsInteg = integLib.mkIntegration {
    name = "bindports";
    manifest = enabledSystem.config.services.spaces-integrations.integrations.bindports;
    landlockPolicyCli = "unused-here";
    landlockExec = "unused-here";
  };
  bindportsDef = bindportsInteg.definition;
  # ── confined extraService (proton groundwork) + bare-string regression ──────
  bridgeSvc = enabledSystem.config.systemd.user.services."spaces-protonlike-bridge";
  bridgeSvcStripped = builtins.removeAttrs bridgeSvc.serviceConfig [
    "ExecStart"
    "ExecStartPre"
  ];
  protonlikeInteg = integLib.mkIntegration {
    name = "protonlike";
    manifest = enabledSystem.config.services.spaces-integrations.integrations.protonlike;
    landlockPolicyCli = "unused-here";
    landlockExec = "unused-here";
  };
  protonlikeDef = protonlikeInteg.definition;
  bridgeSpecFile = protonlikeInteg.extraServiceSpecs."spaces-protonlike-bridge";
  bareInteg = integLib.mkIntegration {
    name = "barehost";
    manifest = enabledSystem.config.services.spaces-integrations.integrations.barehost;
    landlockPolicyCli = "unused-here";
    landlockExec = "unused-here";
  };
  bareBackingSvc = enabledSystem.config.systemd.user.services."spaces-external-daemon";
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
# tempfile surface: the deny-by-default Landlock domain grants no host /tmp.
# Every confined unit gets a private per-unit tmpfs instead
# (PrivateTmp=disconnected); the policy CLI grants /tmp + /var/tmp rw inside
# that namespace (landlock-policy-cli.test.ts), so tempfile in the server works
# without TMPDIR games or host-/tmp exposure.
assert ghSvc.serviceConfig.PrivateTmp == "disconnected";
assert !(lib.any (lib.hasInfix "TMPDIR=") ghSvc.serviceConfig.Environment);
assert lib.hasInfix "/bin/landlock-exec " ghSvc.serviceConfig.ExecStart;
assert lib.hasInfix "--json %t/spaces-integration-github/landlock.json --"
  ghSvc.serviceConfig.ExecStart;
assert lib.hasInfix "integration-github-placeholder" ghSvc.serviceConfig.ExecStart;
# The definition is the safe contract surface — never the command or a secret value.
assert ghDef.autoRun == [ "get_repo" ];
assert ghDef.network;
assert ghDef ? secrets && ghDef.secrets ? token;
assert ghDef.secrets.token.required;
assert ghDef.multiProfile;
assert ghDef ? config && ghDef.config ? owner;
assert !(ghDef ? command);
# bindPorts posture rides the world-readable definition next to connectPorts: the
# bind-ports bridge lists its bind ports, an integration without any lists none.
assert
  bindportsDef.bindPorts == [
    1143
    1025
  ];
assert ghDef.bindPorts == [ ];
# ── Broker unit (step 2): user-scoped host+tpm2 secret path, never pure tpm2 ─
assert lib.hasSuffix "/bin/spaces-integrationd" brokerSvc.serviceConfig.ExecStart;
assert brokerSvc.serviceConfig.StateDirectory == "spaces-integrationd";
assert lib.hasInfix "--with-key=host+tpm2" brokerSvc.environment.SPACES_INTEGRATIOND_CREDS_ENCRYPT;
assert lib.hasInfix "%t/spaces-integrations.sock" brokerSvc.environment.SPACES_INTEGRATIOND_SOCKET;
# ── Confined extraService (proton groundwork): a backing vendor daemon wrapped
# in landlock-exec, NOT socket-activated ────────────────────────────────────
# policy lowering pre-start into the daemon's own runtime dir.
assert lib.any (lib.hasInfix "/bin/spaces-landlock-policy ") bridgeSvc.serviceConfig.ExecStartPre;
assert lib.any (lib.hasInfix "--out %t/spaces-protonlike-bridge/landlock.json")
  bridgeSvc.serviceConfig.ExecStartPre;
# confined ExecStart through the launcher, execing the vendor command.
assert lib.hasInfix "/bin/landlock-exec " bridgeSvc.serviceConfig.ExecStart;
assert lib.hasInfix "--json %t/spaces-protonlike-bridge/landlock.json --"
  bridgeSvc.serviceConfig.ExecStart;
assert lib.hasInfix "protonmail-bridge-placeholder" bridgeSvc.serviceConfig.ExecStart;
# resident, not socket-activated.
assert bridgeSvc.wantedBy == [ ];
# same private-tmpfs posture as the MCP unit (shared hardening bouquet).
assert bridgeSvc.serviceConfig.PrivateTmp == "disconnected";
# PartOf injected by the module (GUI teardown) AND the entry's ConditionPathExists
# gate carried verbatim — both fold onto the SAME unit's [Unit] section.
assert bridgeSvc.unitConfig.PartOf == [ "spaces-integration-protonlike.socket" ];
assert
  bridgeSvc.unitConfig.ConditionPathExists
  == "%h/.local/state/protonmail-bridge/config/protonmail/bridge-v3/vault.enc";
# NO credentials / StateDirectory: the vendor daemon owns its state via extraPaths.
assert !(bridgeSvc.serviceConfig ? LoadCredential);
assert !(bridgeSvc.serviceConfig ? LoadCredentialEncrypted);
assert !(bridgeSvc.serviceConfig ? StateDirectory);
# definition.extraServices carries just the NAME regardless of form; setupPark verbatim.
assert protonlikeDef.extraServices == [ "spaces-protonlike-bridge.service" ];
assert protonlikeDef.setupPark == [ "spaces-protonlike-bridge.service" ];
# the socket Wants/After the backing unit NAME.
assert protonlikeInteg.socketUnit.wants == [ "spaces-protonlike-bridge.service" ];
assert protonlikeInteg.socketUnit.after == [ "spaces-protonlike-bridge.service" ];
# ── Bare-string extraService: today's EXACT behavior (regression) ────────────
# name flows to socket Wants/After + definition; NO confined unit generated.
assert bareInteg.socketUnit.wants == [ "spaces-external-daemon.service" ];
assert bareInteg.socketUnit.after == [ "spaces-external-daemon.service" ];
assert bareInteg.definition.extraServices == [ "spaces-external-daemon.service" ];
assert bareInteg.definition.setupPark == [ ];
assert bareInteg.extraServiceUnits == { };
# the module still injects PartOf (lifecycle) but emits no ExecStart — the daemon
# is owned/run by another module.
assert bareBackingSvc.unitConfig.PartOf == [ "spaces-integration-barehost.socket" ];
assert !(bareBackingSvc.serviceConfig ? ExecStart);
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
    wpSpecFile = wpInteg.policySpecFile;
    bindportsSpecFile = bindportsInteg.policySpecFile;
    bindportsDefinition = builtins.toJSON bindportsDef;
    bridgeServiceConfig = builtins.toJSON bridgeSvcStripped;
    protonlikeDefinition = builtins.toJSON protonlikeDef;
    inherit bridgeSpecFile;
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
    sc '.LoadCredentialEncrypted == ["secrets:%S/spaces-integrationd/github/secrets"]'
    # The managed directory credential (agent-integrations §10.3) rides last on
    # EVERY MCP unit, unconditional — the stager always creates the per-user dir.
    sc '.LoadCredential == ["config:%S/spaces-integrationd/github/config.toml","managed:/run/spaces-integrations-managed/%u/github"]'
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
    notes '.LoadCredential == ["managed:/run/spaces-integrations-managed/%u/notes"]'

    # ── 3. socket-activation endpoint ───────────────────────────────
    sock '.ListenStream == "%t/spaces-integration-github.sock"'

    # ── 4. definition = safe contract (no command, no secret value) ─
    def '.autoRun == ["get_repo"]'
    def '.multiProfile == true'
    def '.secrets.token.description | length > 0'
    def '.secrets.token.required == true'
    def '.config.owner.description | length > 0'
    def 'has("command") | not'
    def '.bindPorts == []'
    [ "$hasEtc" = "yes" ] || fail "github definition not wired into /etc"

    # ── 5. disabled / undeclared module generates nothing ───────────
    [ "$disabledHasGithub" = "no" ] || fail "disabled module still declared a github unit"

    # ── 6. the CLI lowers a deny-by-default policy ──────────────────
    # exactly StateDirectory + private tmpfs (rw) + credentials(ro) + 443; nothing else.
    policy=$PWD/landlock.json
    env STATE_DIRECTORY=/sample/state CREDENTIALS_DIRECTORY=/sample/cred \
      spaces-landlock-policy --spec "$specFile" --out "$policy"
    jq -e '.abi == 6' "$policy" >/dev/null || fail "policy abi"
    jq -e '.ruleset == [{"scoped":["signal","abstract_unix_socket"],"handledAccessNet":["bind_tcp"]}]' "$policy" >/dev/null \
      || fail "policy IPC scope"
    jq -e '.netPort == [{"allowedAccess":["connect_tcp"],"port":[443]}]' "$policy" >/dev/null \
      || fail "egress not locked to 443"
    jq -e '[.pathBeneath[] | select(.allowedAccess | index("abi.read_write")) | .parent] == [["/sample/state", "/tmp", "/var/tmp"]]' "$policy" >/dev/null \
      || fail "writable surface != StateDirectory + private tmpfs"
    jq -e 'any(.pathBeneath[]; (.parent | index("/sample/cred")) and (.allowedAccess | index("read_file")) and (.allowedAccess | index("write_file") | not))' "$policy" >/dev/null \
      || fail "credentials mount not read-only"
    jq -e '[.pathBeneath[].parent[]] | (index("/sample") == null) and (index("/home") == null)' "$policy" >/dev/null \
      || fail "policy granted an unexpected path"

    # ── 7. file exchange (step 6): when systemd resolves the shared dir, the CLI
    # folds it into the writable surface — the SAME dir the agent session grants
    # itself rw. Unset above (section 6) ⇒ rw is StateDirectory + private tmpfs.
    policy2=$PWD/landlock-shared.json
    env STATE_DIRECTORY=/sample/state CREDENTIALS_DIRECTORY=/sample/cred \
        SPACES_INTEGRATION_SHARED_DIR=/sample/share \
      spaces-landlock-policy --spec "$specFile" --out "$policy2"
    jq -e '([.pathBeneath[] | select(.allowedAccess | index("abi.read_write")) | .parent[]]) as $rw
           | (($rw | index("/sample/state")) != null) and (($rw | index("/sample/share")) != null)' \
      "$policy2" >/dev/null || fail "shared dir not granted rw when SPACES_INTEGRATION_SHARED_DIR set"

    # ── 8. extraPaths (step 2): spec carries the grants; the CLI folds them ──
    # The extraPaths-bearing integration's SPEC lists both grants verbatim; the
    # CLI expands any %t/%h at unit start (here literal, so byte-for-byte).
    jq -e '.extraPaths == [{"source":"/run/user/1000/signal-cli","mode":"rw"},{"source":"/home/x/.local/share/signal-cli/attachments","mode":"ro"}]' \
      "$wpSpecFile" >/dev/null || fail "extraPaths missing from policy spec"

    # Deny-by-default unchanged: an integration WITHOUT extraPaths emits NO
    # extraPaths key — byte-identical to the pre-mechanism spec shape.
    jq -e 'has("extraPaths") | not' "$specFile" >/dev/null \
      || fail "extraPaths key leaked into an integration that declared none"
    jq -e '. == {"abi":6,"bindPorts":[],"connectPorts":[443],"scope":["signal","abstract_unix_socket"]}' \
      "$specFile" >/dev/null || fail "no-extraPaths spec not byte-identical to before"

    # Lowering routes rw→writable set, ro→read-only set (nothing else granted).
    wppolicy=$PWD/landlock-withpaths.json
    env STATE_DIRECTORY=/sample/state spaces-landlock-policy --spec "$wpSpecFile" --out "$wppolicy"
    jq -e '[.pathBeneath[] | select(.allowedAccess | index("abi.read_write")) | .parent[]] as $rw
           | (($rw | index("/sample/state")) != null) and (($rw | index("/run/user/1000/signal-cli")) != null)' \
      "$wppolicy" >/dev/null || fail "rw extraPath not folded into the writable set"
    jq -e 'any(.pathBeneath[]; (.parent | index("/home/x/.local/share/signal-cli/attachments")) and (.allowedAccess | index("read_file")) and (.allowedAccess | index("write_file") | not))' \
      "$wppolicy" >/dev/null || fail "ro extraPath not folded into the read-only set"
    jq -e '[.pathBeneath[] | select(.allowedAccess | index("abi.read_write")) | .parent[]] | index("/home/x/.local/share/signal-cli/attachments") == null' \
      "$wppolicy" >/dev/null || fail "ro extraPath leaked into the writable set"

    # ── 9. bindPorts (proton-mail groundwork): the listening bridge grants
    # bind_tcp on EXACTLY its declared ports; egress stays closed. The spec
    # carries bindPorts verbatim; the CLI lowers it into one bind_tcp netPort rule.
    jq -e '.bindPorts == [1143, 1025]' "$bindportsSpecFile" >/dev/null \
      || fail "bindPorts missing from the bind-ports policy spec"
    bindpolicy=$PWD/landlock-bindports.json
    env STATE_DIRECTORY=/sample/state spaces-landlock-policy --spec "$bindportsSpecFile" --out "$bindpolicy"
    jq -e '.netPort == [{"allowedAccess":["bind_tcp"],"port":[1143,1025]}]' "$bindpolicy" >/dev/null \
      || fail "bind ports not lowered to exactly [1143,1025]"
    # Deny-by-default: bind_tcp is handled for the bind integration…
    jq -e '.ruleset[0].handledAccessNet == ["bind_tcp"]' "$bindpolicy" >/dev/null \
      || fail "bind_tcp not handled (deny-by-default) for the bind-ports integration"
    # …and equally for one that declares NO bind ports (section 6's $policy): it
    # grants no bind rule yet still handles bind_tcp, so any unlisted bind is denied.
    jq -e '.ruleset[0].handledAccessNet == ["bind_tcp"]' "$policy" >/dev/null \
      || fail "bind_tcp not handled (deny-by-default) for a no-bind integration"
    jq -e 'any(.netPort[]?; .allowedAccess | index("bind_tcp")) | not' "$policy" >/dev/null \
      || fail "no-bind integration unexpectedly granted a bind rule"
    # The definition surfaces the posture next to connectPorts (panel shows it on
    # manifest approval): the bridge lists its bind ports.
    jq -e '.bindPorts == [1143, 1025]' <<<"$bindportsDefinition" >/dev/null \
      || fail "bindPorts not surfaced in the bind-ports definition"

    # ── 10. confined extraService (proton groundwork): the backing vendor daemon
    # runs Landlock-confined, NOT socket-activated, credential-free ──
    bridge() { jq -e "$1" <<<"$bridgeServiceConfig" >/dev/null || fail "bridge serviceConfig: $1"; }
    bridge '.Type == "exec"'
    # network = true → IP egress at the family layer.
    bridge '.RestrictAddressFamilies == "AF_UNIX AF_INET AF_INET6"'
    # the SAME hardening bouquet as the MCP unit.
    bridge '.NoNewPrivileges == true'
    bridge '.RestrictNamespaces == true'
    bridge '.ProtectProc == "invisible"'
    bridge '.SystemCallFilter | index("@system-service") != null'
    bridge 'any(.SystemCallFilter[]; startswith("~ptrace"))'
    bridge '.SystemCallErrorNumber == "EPERM"'
    # resilient resident daemon: restart=true → Restart=always + RestartSec.
    bridge '.Restart == "always"'
    bridge '.RestartSec == 2'
    # only a runtime dir for the policy; no StateDirectory/credentials.
    bridge '.RuntimeDirectory == "spaces-protonlike-bridge"'
    bridge 'has("StateDirectory") | not'
    bridge 'has("LoadCredential") | not'
    bridge 'has("LoadCredentialEncrypted") | not'
    # the vendor daemon's own env passes through (no SPACES_INTEGRATION_SHARED_DIR).
    bridge '.Environment | index("SPACES_PROTON_BRIDGE_STATE=%h/.local/state/protonmail-bridge") != null'
    bridge 'any(.Environment[]; startswith("SPACES_INTEGRATION_SHARED_DIR=")) | not'

    # the daemon's policy SPEC carries its own bindPorts/connectPorts/extraPaths.
    jq -e '.bindPorts == [1143, 1025]' "$bridgeSpecFile" >/dev/null \
      || fail "bridge spec missing bindPorts"
    jq -e '.connectPorts == [443]' "$bridgeSpecFile" >/dev/null \
      || fail "bridge spec missing connectPorts"
    jq -e '.extraPaths == [{"source":"%h/.local/state/protonmail-bridge","mode":"rw"}]' "$bridgeSpecFile" >/dev/null \
      || fail "bridge spec missing extraPaths"
    # lower it with the real CLI exactly as the unit would at runtime (no
    # StateDirectory; %h resolves from HOME): egress 443 + bind 1143/1025, and the
    # writable surface is the private tmpfs + the rw extraPath (%h expanded).
    # Deny-by-default holds.
    bridgepolicy=$PWD/landlock-bridge.json
    env HOME=/home/x spaces-landlock-policy --spec "$bridgeSpecFile" --out "$bridgepolicy"
    jq -e '.netPort == [{"allowedAccess":["connect_tcp"],"port":[443]},{"allowedAccess":["bind_tcp"],"port":[1143,1025]}]' \
      "$bridgepolicy" >/dev/null || fail "bridge ports not lowered to egress 443 + bind 1143/1025"
    jq -e '[.pathBeneath[] | select(.allowedAccess | index("abi.read_write")) | .parent[]] == ["/tmp", "/var/tmp", "/home/x/.local/state/protonmail-bridge"]' \
      "$bridgepolicy" >/dev/null || fail "bridge writable surface != private tmpfs + its %h-expanded state dir"
    jq -e '.ruleset[0].handledAccessNet == ["bind_tcp"]' "$bridgepolicy" >/dev/null \
      || fail "bind_tcp not handled (deny-by-default) for the confined bridge"

    # the definition carries just the NAME + setupPark verbatim (broker/gateway
    # contract: unit names only, regardless of the confined form).
    jq -e '.extraServices == ["spaces-protonlike-bridge.service"]' <<<"$protonlikeDefinition" >/dev/null \
      || fail "confined extraService leaked more than its name into the definition"
    jq -e '.setupPark == ["spaces-protonlike-bridge.service"]' <<<"$protonlikeDefinition" >/dev/null \
      || fail "setupPark not carried verbatim into the definition"
    jq -e 'has("command") | not' <<<"$protonlikeDefinition" >/dev/null \
      || fail "definition leaked a command"

    touch "$out"
  ''
