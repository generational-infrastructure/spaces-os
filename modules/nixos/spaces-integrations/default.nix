# Agent integrations — the NixOS adapter (docs/agent-integrations-design.md §5,
# docs/agent-integrations-poc-plan.md).
#
# Declaring `services.spaces-integrations.integrations.<name> = { … }` emits,
# per integration:
#   - systemd.user.services."spaces-integration-<name>" — the socket-activated,
#     Landlock-confined MCP server (ExecStartPre lowers the per-user policy;
#     ExecStart execs the server through landlock-exec);
#   - systemd.user.sockets."spaces-integration-<name>" — its unix socket at
#     %t/spaces-integration-<name>.sock that the supervisor gateway connects to;
#   - /etc/spaces-integrations/<name>.json — the world-readable definition the
#     gateway / broker / panel read (posture + secret prompts + autoRun).
#
# All lowering lives in ./lib.nix (backend-agnostic); this file only maps that
# neutral data onto the NixOS user-unit / etc surfaces, so a home-manager
# adapter can reuse the same lib. The broker (step 2) owns enable/disable +
# secret provisioning at runtime — using an integration stays rootless (req 10).
# Bundled by modules/nixos/spaces.nix; inert until enabled AND integrations declared.
{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  cfg = config.services.spaces-integrations;
  integLib = import ./lib.nix {
    inherit pkgs lib;
    inherit (pkgsSelf.pi-sessiond) seccompDenylist;
  };

  pkgsSelf = inputs.self.packages.${pkgs.stdenv.hostPlatform.system};
  # The policy generator rides as a passthru of the pi-sessiond package (it
  # reuses sandbox.ts's buildLandlockPolicy) but carries no pi closure of its
  # own. landlock-exec is the shared launcher.
  landlockPolicyCli = lib.getExe pkgsSelf.pi-sessiond.landlockPolicy;
  landlockExec = lib.getExe pkgsSelf.landlock-exec;

  fieldSubmodule = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        description = "What this field is, shown in the settings panel's provisioning form.";
      };
      required = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether a profile must set this field before the integration can be
          enabled. Optional fields default server-side.
        '';
      };
    };
  };

  extraPathSubmodule = lib.types.submodule {
    options = {
      source = lib.mkOption {
        type = lib.types.str;
        description = ''
          Absolute path granted to the integration's Landlock domain beyond its
          implicit StateDirectory (rw) + credentials mount (ro). May embed
          systemd `%t` ($XDG_RUNTIME_DIR) / `%h` ($HOME) specifiers, which the
          spaces-landlock-policy CLI resolves at unit start — the policy spec is
          a store file, so systemd never expands specifiers inside its contents.
        '';
      };
      mode = lib.mkOption {
        type = lib.types.enum [
          "ro"
          "rw"
        ];
        description = ''
          Access mode: `ro` folds `source` into the read set, `rw` into the
          writable set of the lowered Landlock policy.
        '';
      };
    };
  };

  # A confined extraService: this module materialises a full Landlock-confined
  # resident systemd user service for a backing vendor daemon (e.g. Proton
  # Bridge), wrapped in the same landlock-exec launcher + hardening bouquet as
  # the MCP unit. Contrast the bare-string form of `extraServices`, which only
  # wires lifecycle onto a unit owned/run by another module (signal's precedent).
  extraServiceSubmodule = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = ''
          Full user service unit name (incl. `.service`) this module emits for
          the backing daemon. Its Landlock-confined unit is keyed by this name
          minus `.service`; the integration's `.socket` gains `Wants=`/`After=`
          it and the module injects `PartOf=spaces-integration-<name>.socket`.
        '';
      };
      command = lib.mkOption {
        type = lib.types.str;
        description = ''
          The daemon's ExecStart line, run through landlock-exec. Whitespace-split
          by systemd — no shell.
        '';
      };
      description = lib.mkOption {
        type = lib.types.str;
        description = "Human-readable unit description for the backing daemon.";
      };
      network = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Grant the daemon outbound IP (AF_INET/AF_INET6). Off => AF_UNIX only.
          `connectPorts` refines WHICH TCP ports when on.
        '';
      };
      connectPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
        description = "Port-granular TCP egress allowlist (Landlock netPort), like the integration's own.";
      };
      bindPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
        description = ''
          Port-granular TCP bind allowlist (Landlock netPort, bind_tcp) — e.g. a
          mail bridge's local IMAP/SMTP ports. Empty (default) => bind stays
          denied. Requires `network = true` for the AF_INET family gate.
        '';
      };
      extraPaths = lib.mkOption {
        type = lib.types.listOf extraPathSubmodule;
        default = [ ];
        description = ''
          Host paths folded into the daemon's Landlock policy (`{ source; mode; }`,
          mode `ro`|`rw`, sources may carry `%t`/`%h`). This is how a vendor daemon
          reaches its own state dir (rw) — it gets no StateDirectory/credentials.
        '';
      };
      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = ''
          Environment variables for the daemon unit (values may carry systemd
          `%t`/`%h` specifiers, expanded by systemd). No SPACES_INTEGRATION_SHARED_DIR
          is injected — a vendor daemon is not the agent-facing MCP server.
        '';
      };
      unitConfig = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = ''
          Free-form `[Unit]` directives folded onto the emitted unit, e.g.
          `ConditionPathExists` to gate the daemon on a vault file so a
          pre-onboarding start is inert. Merged with the module's injected
          `PartOf`.
        '';
      };
      restart = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          When true the resident daemon gets `Restart=always` + a short
          `RestartSec` (a resilient companion process, e.g. Proton Bridge). A
          dedicated boolean rather than a free-form serviceConfig passthrough:
          the materialiser owns the sandbox shape (hardening,
          RestrictAddressFamilies, confinement) and never lets a manifest
          override it — each real need gets a named, typed option instead.
        '';
      };
    };
  };

  integrationSubmodule = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        description = "Human-readable integration name, shown to the user and the agent.";
      };
      command = lib.mkOption {
        type = lib.types.str;
        description = ''
          The integration's MCP server invocation (the ExecStart line, run
          through landlock-exec). Whitespace-split by systemd — no shell.
        '';
      };
      network = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Grant the server outbound IP (AF_INET/AF_INET6). Off => AF_UNIX only,
          so the server can serve its activation socket but reach no network.
          `connectPorts` refines WHICH TCP ports when on.
        '';
      };
      connectPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
        description = ''
          Port-granular TCP egress allowlist (Landlock netPort). Non-empty =>
          only these ports are dialable and every other TCP connect is denied.
          Empty with `network = true` => all ports (coarse). Ignored when
          network is off.
        '';
      };
      bindPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
        description = ''
          Port-granular TCP bind allowlist (Landlock netPort, bind_tcp). Non-empty
          => the server may listen only on these ports; every other bind is denied.
          Empty (the default) => the server may not listen at all — bind stays
          denied by default. Used e.g. by a mail bridge exposing a local IMAP/SMTP
          port. Requires `network = true` for the AF_INET family gate.
        '';
      };
      extraPaths = lib.mkOption {
        type = lib.types.listOf extraPathSubmodule;
        default = [ ];
        description = ''
          Extra host paths folded into the Landlock policy by
          spaces-landlock-policy, beyond the implicit StateDirectory (rw) and
          credentials mount (ro). Each entry is `{ source; mode; }` with mode
          `ro`|`rw`; sources may carry systemd `%t`/`%h` specifiers. Empty (the
          default) keeps the deny-by-default posture — exactly StateDir +
          credentials + declared egress. Used e.g. by signal to reach the daemon
          socket dir (rw) and the read-only attachments store.
        '';
      };
      secrets = lib.mkOption {
        type = lib.types.attrsOf fieldSubmodule;
        default = { };
        description = ''
          Secret fields (per profile) the broker seals with host+tpm2 into the
          `secrets` blob credential ($CREDENTIALS_DIRECTORY/secrets); provisioned
          through the panel, never in the Nix store.
        '';
      };
      config = lib.mkOption {
        type = lib.types.attrsOf fieldSubmodule;
        default = { };
        description = ''
          Non-secret connection fields (per profile) delivered plaintext via the
          `config` blob credential ($CREDENTIALS_DIRECTORY/config) — hosts, ports,
          usernames. Entered through the panel like secrets, but not masked.
        '';
      };
      autoRun = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Tools the gateway may run without per-call confirmation. Every other
          tool the server exposes stays callable but confirm-per-call. Empty =>
          all-confirm (the safe default). Tool SCHEMAS are discovered at runtime
          from the server, never declared here.
        '';
      };
      multiProfile = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether this integration holds several accounts (profiles). The panel
          shows profile management when true; when false it provisions a single
          implicit "default" profile. The store is profile-keyed either way.
        '';
      };
      confirmPreview = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = ''
          Per-tool preview map: a confirm tool name -> the gateway-only preview
          tool the gateway calls (same socket, same args) before raising the
          approval prompt. The preview's output becomes the approval's untrusted
          `context` (rendered as plain quoted text). A preview error/timeout
          fails closed (the tool errors, no prompt). Preview tools listed here
          are never child-callable and must never appear in `autoRun`.
        '';
      };
      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = ''
          Extra environment variables for the MCP server unit, folded into
          serviceConfig.Environment alongside SPACES_INTEGRATION_SHARED_DIR.
          Values may carry systemd `%t`/`%h` specifiers (expanded by systemd).
          Used e.g. by signal to point the server at the signal-cli daemon
          socket + message store the host grants via `extraPaths`.
        '';
      };
      extraServices = lib.mkOption {
        type = lib.types.listOf (lib.types.either lib.types.str extraServiceSubmodule);
        default = [ ];
        description = ''
          Backing services that share this integration's GUI lifecycle. Each entry
          is EITHER a bare unit-name string (incl. `.service`) — the daemon is
          owned/run by another module and this module only wires lifecycle
          (signal's precedent) — OR a confined attrset (see extraServiceSubmodule),
          in which case this module ALSO materialises a full Landlock-confined
          resident unit for it. Either way the integration's `.socket` gains
          `Wants=`/`After=` the unit NAME and the module injects
          `PartOf=spaces-integration-<name>.socket` onto it so a GUI disable
          (socket stop) tears the backing daemons down too. The world-readable
          definition carries only the NAMEs (the broker try-restarts them after a
          successful setup).
        '';
      };
      setupPark = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Full user unit names the broker stops for the duration of a setup flow
          (link or remove) and starts again on the way out — single-instance
          vendor daemons (e.g. Proton Bridge) the sandboxed setup helper must
          displace to spawn its own transient instance. Lowered verbatim into the
          definition's `setupPark` (json key `setupPark`); the broker already
          parses it. Default [] (signal declares none).
        '';
      };
      setup = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Setup command line (like `command`: whitespace-split by systemd, no
          shell). When non-null lib.nix emits a twin
          `spaces-integration-<name>-setup.{service,socket}` pair — an IDENTICAL
          sandbox to the main server, only the ExecStart differs — that the
          broker activates to stream the setup helper's NDJSON events to the
          panel (design §5.5). Used e.g. by signal for GUI QR device-linking.
        '';
      };
    };
  };

  built = lib.mapAttrs (
    name: manifest:
    integLib.mkIntegration {
      inherit
        name
        manifest
        landlockPolicyCli
        landlockExec
        ;
      inherit (cfg) memoryHigh;
    }
  ) cfg.integrations;

  # Twin setup service/socket for every integration that declares `setup`. Both
  # maps share one body, differing only by which twin field they pick.
  pickSetup =
    field:
    lib.concatMapAttrs (
      _: i: lib.optionalAttrs (i.${field} != null) { ${i.setupUnitName} = i.${field}; }
    ) built;
  setupServices = pickSetup "setupServiceUnit";
  setupSockets = pickSetup "setupSocketUnit";

  # Reverse edge of each integration's `extraServices`: inject
  # PartOf=spaces-integration-<name>.socket into the backing units (owned by
  # OTHER modules, e.g. signal-cli) so stopping the socket stops them. mkMerge
  # keeps this composable with those modules' own unitConfig.
  extraServicesPartOf = lib.mkMerge (
    lib.concatLists (
      lib.mapAttrsToList (
        name: i:
        map (svc: {
          ${lib.removeSuffix ".service" svc}.unitConfig.PartOf = [ "spaces-integration-${name}.socket" ];
        }) i.extraServiceNames
      ) built
    )
  );

  # Confined form of extraServices: each integration may materialise full
  # Landlock-confined resident units for its backing vendor daemons (bare-string
  # entries contribute none), keyed by unit name minus `.service`.
  extraServiceUnits = lib.mkMerge (lib.mapAttrsToList (_: i: i.extraServiceUnits) built);

  # ── Nix-managed per-user integration profiles (agent-integrations §10) ──────
  # `spaces.users` (the pure-data namespace in ../spaces-users.nix) lowered to a
  # root stager + a per-user staged credential tree. mkManaged validates; the
  # stager materialises. The one added unit line lives in lib.nix's mkServiceUnit.
  usersCfg = config.spaces.users;
  managed = integLib.mkManaged {
    users = usersCfg;
    integrations = cfg.integrations;
    knownUsers = builtins.attrNames config.users.users;
  };

  managedRoot = "/run/spaces-integrations-managed";
  normalUsers = lib.filterAttrs (_: u: u.isNormalUser) config.users.users;
  allIntegrationNames = lib.attrNames cfg.integrations;
  # Stage only for users that are BOTH declared in spaces.users AND normal: the
  # per-user dir loop owns dir creation for normal users, and a non-existent
  # username is reported by mkManaged (never silently staged into a bad chown).
  stagedUsers = lib.filterAttrs (uname: _: normalUsers ? ${uname}) usersCfg;

  userOwn = uname: "-o ${uname} -g ${config.users.users.${uname}.group}";
  managedIntegrationsOf =
    uconf: lib.filterAttrs (iname: _: cfg.integrations ? ${iname}) uconf.integrations;

  # `file =` config refs for a user → one jq shell var each (the index gives a
  # valid, unique identifier even when field names carry `-`).
  fileRefsOf =
    mi:
    lib.imap0 (i: r: r // { var = "f${toString i}"; }) (
      lib.concatLists (
        lib.mapAttrsToList (
          iname: ientry:
          lib.concatLists (
            lib.mapAttrsToList (
              pname: profile:
              lib.concatMap (
                field:
                let
                  v = profile.config.${field};
                in
                lib.optional (!builtins.isString v) {
                  inherit iname pname field;
                  path = v.file;
                }
              ) (lib.attrNames profile.config)
            ) ientry.profiles
          )
        ) mi
      )
    );
  varOf =
    refs: iname: pname: field:
    (lib.findFirst (r: r.iname == iname && r.pname == pname && r.field == field) null refs).var;

  # jq object expression for managed.json's `integrations` map: literals inlined
  # as JSON, `file =` config values referenced as $fN (resolved at stage time),
  # `secrets` reduced to the declared field-name list (values never appear).
  cfgValueExpr =
    refs: iname: pname: field: v:
    if builtins.isString v then builtins.toJSON v else "$" + varOf refs iname pname field;
  profileExpr =
    refs: iname: pname: profile:
    let
      cfgEntries = map (
        field: "${builtins.toJSON field}: ${cfgValueExpr refs iname pname field profile.config.${field}}"
      ) (lib.attrNames profile.config);
    in
    "{ \"config\": { ${lib.concatStringsSep ", " cfgEntries} }, \"secrets\": ${builtins.toJSON (lib.attrNames profile.secrets)} }";
  integExpr =
    refs: iname: ientry:
    let
      profilesPart = lib.optionalString (ientry.profiles != { }) (
        ", \"profiles\": { "
        + lib.concatStringsSep ", " (
          lib.mapAttrsToList (pname: p: "${builtins.toJSON pname}: ${profileExpr refs iname pname p}") ientry.profiles
        )
        + " }"
      );
    in
    "{ \"enable\": ${lib.boolToString ientry.enable}${profilesPart} }";
  integrationsExpr =
    refs: mi:
    "{ "
    + lib.concatStringsSep ", " (
      lib.mapAttrsToList (iname: i: "${builtins.toJSON iname}: ${integExpr refs iname i}") mi
    )
    + " }";

  # managed-config.toml lines for one integration (skill-config TOML: one
  # [<integration>.<profile>] table per profile; literals baked, file= via jq @json).
  tomlLines =
    refs: iname: ientry:
    lib.concatLists (
      lib.mapAttrsToList (
        pname: profile:
        [ "printf '%s\\n' ${lib.escapeShellArg "[${iname}.${pname}]"}" ]
        ++ map (
          field:
          let
            v = profile.config.${field};
          in
          if builtins.isString v then
            "printf '%s\\n' ${lib.escapeShellArg "${field} = ${builtins.toJSON v}"}"
          else
            "printf '${field} = %s\\n' \"$(jq -rn --arg v \"\$${varOf refs iname pname field}\" '$v|@json')\""
        ) (lib.attrNames profile.config)
      ) ientry.profiles
    );

  perIntegrationScript =
    uname: refs: iname: ientry:
    let
      own = userOwn uname;
      intDir = "${managedRoot}/${uname}/${iname}";
    in
    lib.optionals (ientry.profiles != { }) (
      [ "cttmp=\"$(mktemp)\"" ]
      ++ map (l: "${l} >> \"$cttmp\"") (tomlLines refs iname ientry)
      ++ [
        "install -m 0400 ${own} \"$cttmp\" ${intDir}/managed-config.toml"
        "rm -f \"$cttmp\""
      ]
    )
    # secrets are COPIED (never symlinked) so the unit's credential snapshot is stable.
    ++ lib.concatLists (
      lib.mapAttrsToList (
        pname: profile:
        map (
          field:
          "install -m 0400 ${own} ${lib.escapeShellArg profile.secrets.${field}.file} ${intDir}/secret-${pname}-${field}"
        ) (lib.attrNames profile.secrets)
      ) ientry.profiles
    );

  mkUserManagedScript =
    uname: uconf:
    let
      own = userOwn uname;
      userDir = "${managedRoot}/${uname}";
      mi = managedIntegrationsOf uconf;
      refs = fileRefsOf mi;
    in
    lib.optionals (mi != { }) (
      map (r: "${r.var}=\"$(cat ${lib.escapeShellArg r.path})\"") refs
      ++ [
        # `generation` is bumped on EVERY re-stage via `date +%s`: the stager is
        # a runtime script, so wall-clock is a monotonic-enough source, and a
        # secret-only rotation still rewrites managed.json — firing the broker's
        # mtime/generation watch.
        "gen=\"$(date +%s)\""
        "mjtmp=\"$(mktemp)\""
        "jq -n --argjson generation \"$gen\"${lib.concatMapStrings (r: " --arg ${r.var} \"\$${r.var}\"") refs} ${lib.escapeShellArg "{ \"generation\": $generation, \"integrations\": ${integrationsExpr refs mi} }"} > \"$mjtmp\""
        "install -m 0400 ${own} \"$mjtmp\" ${userDir}/managed.json"
        "rm -f \"$mjtmp\""
      ]
      ++ lib.concatLists (lib.mapAttrsToList (perIntegrationScript uname refs) mi)
    );

  # The full stager body. Every normal user gets a per-user root (0500,
  # user-owned) plus a subdir for EVERY declared integration (Phase 0.3: a
  # MISSING credential dir hard-fails the unit, so it must exist unconditionally;
  # an empty one is fine). Users with Nix opinions then get managed.json + the
  # per-integration managed-config.toml/secret files.
  managedStagerScript = lib.concatStringsSep "\n" (
    [
      "set -eu"
      "install -d -m 0755 -o root -g root ${managedRoot}"
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (
        uname: _:
        [ "install -d -m 0500 ${userOwn uname} ${managedRoot}/${uname}" ]
        ++ map (iname: "install -d -m 0500 ${userOwn uname} ${managedRoot}/${uname}/${iname}") allIntegrationNames
      ) normalUsers
    )
    ++ lib.concatLists (lib.mapAttrsToList mkUserManagedScript stagedUsers)
  );
in
{
  # Every consumer of the module gets the 5 default integrations (github,
  # caldav, contacts, mail, signal). Each field is individually mkDefault, so a
  # host can override one sub-option without losing the rest, and may still
  # declare EXTRA integrations alongside them.
  imports = [
    (import ./defaults.nix { inherit inputs; })
    # The pure-data `spaces.users` namespace (../spaces-users.nix) this module
    # consumes + lowers (agent-integrations §10). Imported here so every consumer
    # of spaces-integrations — including the isolated eval checks — sees it.
    inputs.self.nixosModules.spaces-users
  ];

  options.services.spaces-integrations = {
    enable = lib.mkEnableOption "agent integrations: per-user, Landlock-confined MCP servers behind the supervisor gateway";

    memoryHigh = lib.mkOption {
      type = lib.types.str;
      default = "512M";
      description = "MemoryHigh for each integration's MCP server unit.";
    };

    integrations = lib.mkOption {
      type = lib.types.attrsOf integrationSubmodule;
      default = { };
      description = "Agent integrations to materialise, keyed by short name.";
    };
  };

  config = lib.mkMerge [
    # Validate spaces.users regardless of `enable` so a misconfiguration is
    # caught even on a host that has integrations turned off.
    { assertions = managed.assertions; }
    (lib.mkIf cfg.enable {
    # Each user runs their own per-user broker, which seals that user's secrets
    # with `systemd-creds --with-key=host+tpm2` (§5.2) and so needs TPM device
    # access. security.tpm2 provides it — it creates the `tss` group and the
    # /dev/tpmrm0 udev rule. Access is by group membership (the rule carries no
    # uaccess tag), and there is no "all users" group, so grant `tss` to every
    # normal user rather than a single hardcoded account. A VM build of an
    # integrations host also needs a software TPM: set it too, but guarded to
    # where the option exists (a vmVariant / nixosTest node) — never on real
    # hardware, which has a real one.
    security.tpm2.enable = lib.mkDefault true;
    virtualisation = lib.optionalAttrs (options.virtualisation ? tpm) {
      tpm.enable = lib.mkDefault true;
    };
    users.groups.tss.members = builtins.attrNames (
      lib.filterAttrs (_: u: u.isNormalUser) config.users.users
    );

      # Root stager (agent-integrations §10.2), mirroring pi-chat's
      # spaces-secrets-load: a root oneshot that materialises the per-user staged
      # credential tree at boot/switch. Fully generated above; only `generation`
      # and any `file =` values are resolved at runtime.
      systemd.services.spaces-integrations-managed-load = {
        description = "Stage Nix-managed integration profiles into per-user credential trees";
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" ];
        path = [
          pkgs.coreutils
          pkgs.jq
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
        };
        script = managedStagerScript;
      };

    # The broker runs whenever integrations are enabled (even with none declared
    # yet): it owns enable/disable + secret provisioning over
    # %t/spaces-integrations.sock and starts/stops each integration's socket.
    systemd.user.services = lib.mkMerge [
      (lib.mapAttrs' (_: i: lib.nameValuePair i.unitName i.serviceUnit) built)
      setupServices
      extraServicesPartOf
      extraServiceUnits
      {
        spaces-integrationd = {
          description = "Spaces integrations broker (enable + secret provisioning over %t/spaces-integrations.sock)";
          wantedBy = [ "default.target" ];
          # systemd splits an unquoted multi-word `Environment=` value on
          # whitespace; the encrypt/systemctl commands carry args, so they ride
          # the `environment` attrset (NixOS quotes it) rather than a raw
          # serviceConfig.Environment list — otherwise the args are dropped.
          environment = {
            SPACES_INTEGRATIOND_SOCKET = "%t/spaces-integrations.sock";
            SPACES_INTEGRATIOND_DEFS_DIR = "/etc/spaces-integrations";
            # Secret path: user-scoped + TPM2-enforced (host+tpm2, never the
            # insecure `auto` fallback, never pure tpm2 which --uid= rejects).
            SPACES_INTEGRATIOND_CREDS_ENCRYPT = "${pkgs.systemd}/bin/systemd-creds encrypt --user --uid=self --with-key=host+tpm2";
            # Decrypt mirrors the encrypt scope: the broker unseals its own
            # secrets blob to a tmpfs working copy to edit one profile row.
            SPACES_INTEGRATIOND_CREDS_DECRYPT = "${pkgs.systemd}/bin/systemd-creds decrypt --user --uid=self";
            SPACES_INTEGRATIOND_SYSTEMCTL = "${pkgs.systemd}/bin/systemctl --user";
            # Store engine (config.toml + secrets.toml blob); shared with the
            # agent-facing skills so one implementation owns the format.
            SPACES_INTEGRATIOND_SKILL_CONFIG = "${lib.getExe pkgsSelf.skill-config}";
          };
          serviceConfig = {
            Type = "exec";
            ExecStart = lib.getExe pkgsSelf.spaces-integrationd;
            Restart = "on-failure";
            RestartSec = 2;
            StateDirectory = "spaces-integrationd";
            # Tmpfs scratch for the schema file + transient unsealed secrets.toml
            # during an edit — never on the persistent StateDirectory.
            RuntimeDirectory = "spaces-integrationd";
            # Trusted (it holds the encrypt path + the socket) but still
            # unprivileged and hardened — it runs as the user, never root.
            NoNewPrivileges = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectClock = true;
            SystemCallArchitectures = "native";
          };
        };
      }
    ];

    systemd.user.sockets = lib.mkMerge [
      (lib.mapAttrs' (_: i: lib.nameValuePair i.unitName i.socketUnit) built)
      setupSockets
    ];

    environment.etc = lib.mapAttrs' (
      name: i: lib.nameValuePair "spaces-integrations/${name}.json" { source = i.definitionFile; }
    ) built;
    })
  ];
}
