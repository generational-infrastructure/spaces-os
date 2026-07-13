# Backend-agnostic lowering for agent integrations
# (docs/agent-integrations-design.md §5, docs/agent-integrations-poc-plan.md).
#
# Maps one integration manifest -> neutral systemd unit data + a static Landlock
# policy spec + a world-readable definition. ./default.nix is the thin NixOS
# adapter that drops this data into systemd.user.{services,sockets} and
# environment.etc; a home-manager adapter could reuse this lib unchanged.
#
# Two layers confine the (untrusted, same-uid) MCP server:
#   - a Landlock domain (deny-by-default FS allowlist + port-granular TCP egress
#     + IPC scoping), applied by landlock-exec from the policy the
#     spaces-landlock-policy CLI lowers AT UNIT START — the grantable paths
#     ($STATE_DIRECTORY / $CREDENTIALS_DIRECTORY / a shared dir) are per-user and
#     unknown at build time. The static half of that policy (the SPEC) is here.
#   - systemd hardening on the unit: the seccomp denylist (single-sourced from
#     the pi-sessiond package's `seccompDenylist` passthru — the same JSON
#     sandbox.ts imports — closing same-uid kernel objects Landlock can't),
#     RestrictAddressFamilies as the coarse network on/off gate, and the
#     kernel-protection bouquet (mirrors sandbox.ts).
{
  pkgs,
  lib,
  # Path to the seccomp denylist JSON — pass the pi-sessiond package's
  # `seccompDenylist` passthru so the per-session sandbox (sandbox.ts imports
  # the same file) and the integration units subtract one identical set.
  seccompDenylist,
}:
let
  jsonFormat = pkgs.formats.json { };

  # @system-service is the allowlist baseline; this set is subtracted. Blocked
  # calls fail EPERM not SIGSYS (libuv's io_uring probe), matching sandbox.ts.
  denySyscalls = builtins.fromJSON (builtins.readFile seccompDenylist);
in
{
  inherit jsonFormat;

  # manifest -> { unitName, serviceUnit, socketUnit, policySpec, policySpecFile,
  #               definition, definitionFile }. Pure data; no NixOS wiring.
  mkIntegration =
    {
      name,
      manifest,
      landlockPolicyCli, # spaces-landlock-policy binary
      landlockExec, # landlock-exec binary
      memoryHigh ? "512M",
    }:
    let
      unitName = "spaces-integration-${name}";
      # %t = $XDG_RUNTIME_DIR, %S = $XDG_STATE_HOME for a --user unit.
      policyPath = "%t/${unitName}/landlock.json";
      socketPath = "%t/${unitName}.sock";
      # File-exchange dir (design §9.4 step 6): a plain dir the agent SESSION
      # also grants itself rw (same uid, no idmap). clone_to_workspace populates
      # it; the agent edits the tree with its native file tools. Lives outside
      # the private StateDirectory the agent's domain denies wholesale.
      sharedDir = "%t/spaces-integration-share/${name}";
      hasSecrets = manifest.secrets != { };
      hasConfig = manifest.config != { };
      hasSetup = manifest.setup != null;
      # Per-integration store the broker manages under its StateDirectory
      # (spaces-integrationd): config.toml is plaintext config rows -> the
      # `config` LoadCredential; `secrets` is the host+tpm2-sealed secrets.toml
      # blob -> the `secrets` LoadCredentialEncrypted. Profiles are rows INSIDE
      # these two blobs, so the credential set is fixed (at most config+secrets)
      # while accounts stay dynamic (unified blob-credential store).
      storeDir = "%S/spaces-integrationd/${name}";

      # Static half of the Landlock policy (one builder, reused by the main unit
      # and every confined extraService below); the CLI folds in the per-user
      # paths at start. connectPorts / bindPorts are the port-granular TCP egress
      # / ingress allowlists (the coarse AF_INET gate is RestrictAddressFamilies,
      # from `network`). Both ride unconditionally: an empty list lowers to no
      # rule, but bind_tcp stays denied by default (buildLandlockPolicy).
      mkPolicySpec =
        {
          connectPorts,
          bindPorts,
          extraPaths,
        }:
        {
          inherit connectPorts bindPorts;
          abi = 6;
          scope = [
            "signal"
            "abstract_unix_socket"
          ];
        }
        // lib.optionalAttrs (extraPaths != [ ]) {
          # ro → read set, rw → write set (folded by spaces-landlock-policy). Sources
          # keep %t/%h verbatim; the spec is a store file, so systemd never expands
          # them — the CLI resolves them from the unit env ($XDG_RUNTIME_DIR/$HOME).
          extraPaths = map (p: { inherit (p) source mode; }) extraPaths;
        };
      policySpec = mkPolicySpec {
        inherit (manifest) connectPorts bindPorts extraPaths;
      };
      policySpecFile = jsonFormat.generate "${unitName}-policy-spec.json" policySpec;

      # World-readable definition: posture + the panel's secret prompts + the
      # gateway's autoRun allowlist. No secret VALUES, no command line.
      definition = {
        inherit name;
        inherit (manifest)
          description
          network
          connectPorts
          bindPorts
          autoRun
          confirmPreview
          multiProfile
          ;
        # extraServices / setupPark ride as plain unit-NAME strings regardless of
        # the manifest form (bare string or confined attrset) — the broker /
        # gateway only need names: to try-restart the backing daemons after a
        # successful setup (extraServices), and to stop/park single-instance
        # vendor daemons for the duration of a setup flow (setupPark).
        extraServices = extraServiceNames;
        inherit (manifest) setupPark;
        # setup: true iff a twin setup unit exists — the panel gates its
        # Link/Setup button on this.
        setup = hasSetup;
        config = lib.mapAttrs (_: c: { inherit (c) description required; }) manifest.config;
        secrets = lib.mapAttrs (_: s: { inherit (s) description required; }) manifest.secrets;
        socket = socketPath;
      };
      definitionFile = jsonFormat.generate "${unitName}.json" definition;

      # Same-uid hardening bouquet (mirrors sandbox.ts landlockHardeningProps +
      # the shared seccomp denylist): closes the kernel objects Landlock leaves
      # exposed between same-uid sibling domains. RestrictAddressFamilies is the
      # coarse egress gate — AF_INET(6) only when the unit opts into `network`;
      # Landlock netPort refines WHICH ports. Reused verbatim by the main MCP /
      # setup units and every confined extraService (vendor daemon), so the
      # sandbox shape can never drift between them.
      hardeningServiceConfig = network: {
        RestrictAddressFamilies = if network then "AF_UNIX AF_INET AF_INET6" else "AF_UNIX";
        NoNewPrivileges = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        RestrictNamespaces = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectProc = "invisible";
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~${lib.concatStringsSep " " denySyscalls}"
        ];
        SystemCallErrorNumber = "EPERM";
        MemoryHigh = memoryHigh;
      };

      # An extraServices entry is EITHER a bare unit-name string (lifecycle only:
      # the daemon is owned/run by another module — signal's precedent — this
      # module just wires the socket Wants/After + PartOf) OR a confined attrset
      # (this module ALSO materialises a full Landlock-confined resident unit for
      # the backing vendor daemon). Either way the NAME is what the broker /
      # gateway and the reverse PartOf edge consume.
      extraServiceName = svc: if builtins.isString svc then svc else svc.name;
      extraServiceNames = map extraServiceName manifest.extraServices;

      # One record per CONFINED extraService: its systemd key (unit name minus
      # `.service`), the policy SPEC its ExecStartPre lowers, and the full
      # confined resident unit — wrapped in the SAME landlock-exec launcher +
      # hardening bouquet as the MCP unit, closing the inherited gap where
      # extraServices ran unconfined. Unlike the MCP unit it is NOT socket-
      # activated (plain resident, wantedBy = [ ]) and carries NO credentials /
      # shared dir: vendor daemons own their state (granted rw via `extraPaths`,
      # e.g. Proton Bridge's ~/.local/state tree), never the broker's store. Its
      # lifecycle matches the bare form — the integration socket Wants/After
      # pulls it in, PartOf tears it down, and any unitConfig.ConditionPathExists
      # keeps a pre-onboarding start inert. Bare-string entries contribute none.
      confinedEntries = map (
        entry:
        let
          key = lib.removeSuffix ".service" entry.name;
          specFile = jsonFormat.generate "${key}-policy-spec.json" (mkPolicySpec {
            inherit (entry) connectPorts bindPorts extraPaths;
          });
          policyPath = "%t/${key}/landlock.json";
        in
        {
          inherit key specFile;
          unit = {
            inherit (entry) description unitConfig;
            # Resident, not socket-activated: the integration socket Wants/After
            # this unit; it never wants default.target on its own.
            wantedBy = [ ];
            serviceConfig = {
              Type = "exec";
              # Lower the per-user policy into this unit's own runtime dir, then
              # exec the vendor daemon confined by it. No shared dir / credentials.
              ExecStartPre = [
                "${landlockPolicyCli} --spec ${specFile} --out ${policyPath}"
              ];
              ExecStart = "${landlockExec} --json ${policyPath} -- ${entry.command}";
              Environment = lib.mapAttrsToList (k: v: "${k}=${v}") entry.environment;
              # Only the runtime dir (holds the lowered policy); no StateDirectory
              # — the daemon's state lives where `extraPaths` grants it.
              RuntimeDirectory = key;
            }
            // lib.optionalAttrs entry.restart {
              # Resilient resident daemon (e.g. Proton Bridge): always restart,
              # backing off like the broker's own on-failure policy.
              Restart = "always";
              RestartSec = 2;
            }
            // hardeningServiceConfig entry.network;
          };
        }
      ) (builtins.filter (svc: !builtins.isString svc) manifest.extraServices);

      # Keyed by unit name minus `.service` for systemd.user.services; the spec
      # files ride alongside so the eval check can lower them with the real CLI.
      extraServiceUnits = builtins.listToAttrs (map (e: lib.nameValuePair e.key e.unit) confinedEntries);
      extraServiceSpecs = builtins.listToAttrs (
        map (e: lib.nameValuePair e.key e.specFile) confinedEntries
      );

      # One shared serviceConfig builder. The main MCP server and (when
      # manifest.setup != null) the twin setup unit run the SAME sandbox — same
      # Landlock policy spec/path machinery, same seccomp/hardening bouquet, same
      # RestrictAddressFamilies, same Environment (incl. SPACES_INTEGRATION_SHARED_DIR),
      # same LoadCredential[Encrypted], same MemoryHigh — differing ONLY in the
      # ExecStart command, so the setup channel can never drift from the server's
      # confinement.
      mkServiceUnit =
        {
          description,
          execCommand,
        }:
        {
          inherit description;
          # Socket-activated; no wantedBy. The broker owns the socket lifecycle:
          # it `systemctl --user start`s this integration's .socket on enable.
          serviceConfig = {
            Type = "exec";
            # Lower the per-user policy, then exec the command confined. The CLI
            # reads $STATE_DIRECTORY / $CREDENTIALS_DIRECTORY (set by the dirs
            # below) from the env and writes the landlockconfig doc to %t.
            # mkdir the shared dir first (idempotent; the agent session mkdirs the
            # same path too) so it exists before landlock-exec — Landlock skips
            # a missing path, which would silently drop the grant.
            ExecStartPre = [
              "${pkgs.coreutils}/bin/mkdir -p ${sharedDir}"
              "${landlockPolicyCli} --spec ${policySpecFile} --out ${policyPath}"
            ];
            ExecStart = "${landlockExec} --json ${policyPath} -- ${execCommand}";
            # The CLI folds $SPACES_INTEGRATION_SHARED_DIR into the policy's rw set
            # (lowerIntegrationPolicy), and the server reads it as its clone target.
            Environment = [
              "SPACES_INTEGRATION_SHARED_DIR=${sharedDir}"
              # The Landlock domain grants no /tmp: the unit's writable surface
              # is exactly its StateDirectory (+ shared dir). Point TMPDIR
              # inside it so tempfile/mkstemp in the server (himalaya config
              # files, msmtprc scratch dirs) work; without this every mail tool
              # call dies with "No usable temporary directory found". Listed
              # first so a manifest environment entry can override it.
              "TMPDIR=%S/${unitName}"
            ]
            ++ lib.mapAttrsToList (k: v: "${k}=${v}") manifest.environment;
            RuntimeDirectory = unitName;
            StateDirectory = unitName;
            # The broker delivers the whole store as two fixed credentials:
            # `config` (plaintext rows, ro) and `secrets` (host+tpm2 blob,
            # decrypted ro), each in a private mount the agent's Landlock domain
            # never grants. Profiles live inside, so the credential set never grows
            # with accounts. Each is emitted only when the manifest declares fields
            # of that kind.
            LoadCredential = lib.optional hasConfig "config:${storeDir}/config.toml";
            LoadCredentialEncrypted = lib.optional hasSecrets "secrets:${storeDir}/secrets";
          }
          // hardeningServiceConfig manifest.network;
        };

      # Socket-unit shape shared by the main and setup channels; SocketMode
      # single-sourced. `path` is the ListenStream (the pre-bound socketPath for
      # the main socket, the setup unit's %t path for the setup socket).
      socketMode = "0600";
      mkSocketUnit =
        { path, description }:
        {
          inherit description;
          socketConfig = {
            ListenStream = path;
            SocketMode = socketMode;
          };
        };

      serviceUnit = mkServiceUnit {
        description = "Spaces integration: ${manifest.description} (Landlock-confined MCP server)";
        execCommand = manifest.command;
      };

      setupUnitName = "${unitName}-setup";

      # Twin setup unit (design §5.5, sandboxed setup channel). Identical sandbox
      # to the main service — only the ExecStart command differs. The broker
      # activates the socket, connects, and relays the helper's NDJSON events to
      # the panel — bidirectionally: prompt events (text-field / secret-field)
      # flow up, the panel's {"value":...} replies flow back, and set-field
      # events are intercepted broker-side (see spaces-integrationd protocol.go
      # for the full §5.5 vocabulary: qr / message / text-field / secret-field /
      # set-field / done / error).
      setupServiceUnit =
        if hasSetup then
          mkServiceUnit {
            description = "Spaces integration setup: ${manifest.description} (Landlock-confined setup channel)";
            execCommand = manifest.setup;
          }
        else
          null;

      setupSocketUnit =
        if hasSetup then
          # No wantedBy: the broker starts this on demand during the setup flow.
          mkSocketUnit {
            path = "%t/${setupUnitName}.sock";
            description = "Spaces integration setup socket: ${manifest.description}";
          }
        else
          null;

      socketUnit =
        mkSocketUnit {
          path = socketPath;
          description = "Spaces integration socket: ${manifest.description}";
        }
        // lib.optionalAttrs (extraServiceNames != [ ]) {
          # Starting this socket pulls in the integration's backing daemons; the
          # spaces-integrations module injects the reverse PartOf onto each so a
          # GUI disable (socket stop) tears them down too.
          wants = extraServiceNames;
          after = extraServiceNames;
        };
    in
    {
      inherit
        unitName
        serviceUnit
        socketUnit
        setupUnitName
        setupServiceUnit
        setupSocketUnit
        hasSetup
        policySpec
        policySpecFile
        definition
        definitionFile
        extraServiceNames
        extraServiceUnits
        extraServiceSpecs
        ;
    };
}
