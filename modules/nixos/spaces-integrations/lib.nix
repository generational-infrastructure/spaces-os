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
#     + IPC scoping), applied by pi-landlock-exec from the policy the
#     spaces-landlock-policy CLI lowers AT UNIT START — the grantable paths
#     ($STATE_DIRECTORY / $CREDENTIALS_DIRECTORY / a shared dir) are per-user and
#     unknown at build time. The static half of that policy (the SPEC) is here.
#   - systemd hardening on the unit: the seccomp denylist (single-sourced from
#     packages/pi-sessiond/seccomp-denylist.json, closing same-uid kernel
#     objects Landlock can't), RestrictAddressFamilies as the coarse network
#     on/off gate, and the kernel-protection bouquet (mirrors sandbox.ts).
{
  pkgs,
  lib,
}:
let
  jsonFormat = pkgs.formats.json { };

  # The seccomp denylist, single-sourced with the per-session sandbox
  # (packages/pi-sessiond/sandbox.ts imports the same JSON). @system-service is
  # the allowlist baseline; this set is subtracted. Blocked calls fail EPERM not
  # SIGSYS (libuv's io_uring probe), matching sandbox.ts.
  denySyscalls = builtins.fromJSON (
    builtins.readFile ../../../packages/pi-sessiond/seccomp-denylist.json
  );
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
      landlockExec, # pi-landlock-exec binary
      memoryHigh ? "512M",
    }:
    let
      unitName = "spaces-integration-${name}";
      # %t = $XDG_RUNTIME_DIR, %S = $XDG_STATE_HOME for a --user unit.
      policyPath = "%t/${unitName}/landlock.json";
      # File-exchange dir (design §9.4 step 6): a plain dir the agent SESSION
      # also grants itself rw (same uid, no idmap). clone_to_workspace populates
      # it; the agent edits the tree with its native file tools. Lives outside
      # the private StateDirectory the agent's domain denies wholesale.
      sharedDir = "%t/spaces-integration-share/${name}";
      secretNames = lib.attrNames manifest.secrets;

      # Static half of the Landlock policy; the CLI folds in the per-user paths
      # at start. connectPorts is the port-granular TCP egress allowlist (the
      # coarse AF_INET gate is RestrictAddressFamilies, from `network`).
      policySpec = {
        inherit (manifest) connectPorts;
        abi = 6;
        scope = [
          "signal"
          "abstract_unix_socket"
        ];
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
          autoRun
          ;
        secrets = lib.mapAttrs (_: s: { inherit (s) description; }) manifest.secrets;
        socket = "%t/${unitName}.sock";
      };
      definitionFile = jsonFormat.generate "${unitName}.json" definition;

      serviceUnit = {
        description = "Spaces integration: ${manifest.description} (Landlock-confined MCP server)";
        # Socket-activated; no wantedBy. The broker owns the socket lifecycle:
        # it `systemctl --user start`s this integration's .socket on enable.
        serviceConfig = {
          Type = "exec";
          # Lower the per-user policy, then exec the server confined. The CLI
          # reads $STATE_DIRECTORY / $CREDENTIALS_DIRECTORY (set by the dirs
          # below) from the env and writes the landlockconfig doc to %t.
          # mkdir the shared dir first (idempotent; the agent session mkdirs the
          # same path too) so it exists before pi-landlock-exec — Landlock skips
          # a missing path, which would silently drop the grant.
          ExecStartPre = [
            "${pkgs.coreutils}/bin/mkdir -p ${sharedDir}"
            "${landlockPolicyCli} --spec ${policySpecFile} --out ${policyPath}"
          ];
          ExecStart = "${landlockExec} --json ${policyPath} -- ${manifest.command}";
          # The CLI folds $SPACES_INTEGRATION_SHARED_DIR into the policy's rw set
          # (lowerIntegrationPolicy), and the server reads it as its clone target.
          Environment = [ "SPACES_INTEGRATION_SHARED_DIR=${sharedDir}" ];
          RuntimeDirectory = unitName;
          StateDirectory = unitName;
          # Decrypted secrets land in $CREDENTIALS_DIRECTORY/<name> (ro), in a
          # private mount the agent's Landlock domain never grants. Ciphertexts
          # are written user-scoped (host+tpm2) by the broker to %S/spaces-
          # integrationd/<name>/<secret> (step 2).
          LoadCredentialEncrypted = map (s: "${s}:%S/spaces-integrationd/${name}/${s}") secretNames;
          # Coarse egress gate: AF_INET(6) only when the manifest opts in; the
          # passed activation socket is always AF_UNIX. Landlock netPort refines
          # WHICH ports when network is on.
          RestrictAddressFamilies = if manifest.network then "AF_UNIX AF_INET AF_INET6" else "AF_UNIX";
          # Same-uid hardening bouquet (mirrors sandbox.ts landlockHardeningProps
          # + the shared seccomp denylist): closes the kernel objects Landlock
          # leaves exposed between same-uid sibling domains.
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
      };

      socketUnit = {
        description = "Spaces integration socket: ${manifest.description}";
        socketConfig = {
          ListenStream = "%t/${unitName}.sock";
          SocketMode = "0600";
        };
      };
    in
    {
      inherit
        unitName
        serviceUnit
        socketUnit
        policySpec
        policySpecFile
        definition
        definitionFile
        ;
    };
}
