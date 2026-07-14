# Default agent integrations, shipped with the spaces-integrations module so
# EVERY spaces user sees github / caldav / contacts / mail / signal under
# Settings → Integrations without any per-host nix (contract goal 1). Imported
# by ./default.nix.
#
# mkDefault discipline: each sub-attribute is wrapped in lib.mkDefault
# INDIVIDUALLY (never the whole integration attrset), so a host that overrides
# one field (e.g. `github.autoRun`) keeps every other default intact. Hosts may
# still declare EXTRA integrations alongside these (the exception path).
#
# Each integration's config/secrets field schema is single-sourced from the
# schema.json its package ships (pure eval readFile — no server build); the
# relative path from this file is ../../../packages. checks/spaces-integrations-
# schema-sync pins the manifests against those schemas.
{ inputs, ... }:
{
  pkgs,
  lib,
  ...
}:
let
  pkgsSelf = inputs.self.packages.${pkgs.stdenv.hostPlatform.system};
  exe = name: lib.getExe pkgsSelf.${name};
  # The package's exported store contract: { config, secrets, tools }.
  schemaOf =
    name:
    builtins.fromJSON (builtins.readFile (../../../packages + "/integration-${name}/schema.json"));
  configOf = name: (schemaOf name).config;
  secretsOf = name: (schemaOf name).secrets;
  # Name-derived + individually-mkDefault'd triplet every integration shares:
  # command from the integration-<name> package, config/secrets from its schema.
  # `rest` carries the per-integration fields (each mkDefault'd inline); its keys
  # are disjoint from the triplet, so every field keeps its own overridable default.
  mkInteg =
    name: rest:
    {
      command = lib.mkDefault (exe "integration-${name}");
      config = lib.mkDefault (configOf name);
      secrets = lib.mkDefault (secretsOf name);
    }
    // rest;

  # Proton Mail Bridge glue. The env-pinned `protonmail-bridge` wrapper is built
  # from the SAME pure builder the spaces-proton-bridge module uses
  # (../proton-bridge/wrapper.nix) — a plain import, NOT a config read, so this
  # manifest still evaluates in the isolated integration checks that load only
  # nixosModules.spaces-integrations.
  protonWrapper = import ../proton-bridge/wrapper.nix { inherit pkgs lib; };
  protonWrapperExe = lib.getExe protonWrapper;
  # integration-proton-setup spawns a transient `protonmail-bridge --grpc` by
  # resolving `protonmail-bridge` on PATH. The twin setup unit's ExecStart is
  # this `setup` command run through landlock-exec, so prepend the wrapper's bin
  # dir to PATH via a one-token writeShellScript. Wrapping ONLY the setup command
  # keeps the Bridge wrapper off the main MCP server unit's PATH.
  protonSetup = pkgs.writeShellScript "integration-proton-setup" ''
    export PATH=${lib.makeBinPath [ protonWrapper ]}''${PATH:+:$PATH}
    exec ${lib.getExe' pkgsSelf.integration-proton "integration-proton-setup"} "$@"
  '';

  # Proton Bridge single-source bindings: the state root the MCP server, setup
  # helper, and the confined Bridge daemon all share, and the loopback ports the
  # daemon binds / the MCP server dials.
  bridgeState = "%h/.local/state/protonmail-bridge";
  bridgeImapPort = 1143;
  bridgeSmtpPort = 1025;
in
{
  services.spaces-integrations.integrations = {
    github = mkInteg "github" {
      description = lib.mkDefault "GitHub";
      network = lib.mkDefault true;
      connectPorts = lib.mkDefault [ 443 ];
      autoRun = lib.mkDefault [ "get_repo" ];
    };

    # Migrated from the calendar skill: CalDAV over the panel-provisioned,
    # host+tpm2-sealed store. Read tools auto-run; writes confirm per call.
    caldav = mkInteg "caldav" {
      description = lib.mkDefault "Calendar (CalDAV)";
      network = lib.mkDefault true;
      connectPorts = lib.mkDefault [ 443 ];
      multiProfile = lib.mkDefault true;
      autoRun = lib.mkDefault [
        "list"
        "get"
        "etag"
      ];
    };

    # Migrated from the contacts skill: CardDAV.
    contacts = mkInteg "contacts" {
      description = lib.mkDefault "Contacts (CardDAV)";
      network = lib.mkDefault true;
      connectPorts = lib.mkDefault [ 443 ];
      multiProfile = lib.mkDefault true;
      autoRun = lib.mkDefault [
        "discover"
        "search"
        "get"
      ];
    };

    # Migrated from the email skill: IMAP/SMTP via himalaya. send confirms.
    mail = mkInteg "mail" {
      description = lib.mkDefault "Email (IMAP/SMTP)";
      network = lib.mkDefault true;
      connectPorts = lib.mkDefault [
        993
        587
        465
        143
        25
      ];
      multiProfile = lib.mkDefault true;
      autoRun = lib.mkDefault [
        "envelope_list"
        "message_read"
      ];
    };

    # Migrated from the signal skill: the signal-cli daemon over the
    # panel-enabled, field-less store (no config/secrets — device linking is the
    # GUI setup flow below). Read/list tools auto-run; `send` confirms with a
    # rendered `send_preview`. No network: the signal-cli daemon owns the
    # internet, so the integration only reaches the daemon socket + the local
    # message store granted via extraPaths.
    signal = mkInteg "signal" {
      description = lib.mkDefault "Signal";
      network = lib.mkDefault false;
      connectPorts = lib.mkDefault [ ];
      autoRun = lib.mkDefault [
        "threads"
        "read_thread"
        "search"
        "contacts"
        "groups"
        "note_to_self"
        "fetch_attachment"
      ];
      confirmPreview = lib.mkDefault { send = "send_preview"; };
      # The server reads these at start (integration_signal.py); values carry
      # systemd %t/%h specifiers, resolved identically to the extraPaths grants.
      environment = lib.mkDefault {
        SPACES_SIGNAL_DAEMON_SOCKET = "%t/signal-cli/socket";
        SPACES_SIGNAL_ATTACHMENTS_DIR = "%h/.local/share/signal-cli/attachments";
        SPACES_SIGNAL_DB = "%h/.local/state/spaces/signal/messages.db";
      };
      extraPaths = lib.mkDefault [
        {
          # signal-cli daemon JSON-RPC socket dir (rw to connect the AF_UNIX socket).
          source = "%t/signal-cli";
          mode = "rw";
        }
        {
          # messages.db store — rw only for the WAL -wal/-shm side-files; the
          # server opens the DB mode=ro (decision 8).
          source = "%h/.local/state/spaces/signal";
          mode = "rw";
        }
        {
          # signal-cli attachment store — read-only; fetch_attachment copies out.
          source = "%h/.local/share/signal-cli/attachments";
          mode = "ro";
        }
      ];
      # Backing daemons whose lifecycle follows the Signal integration socket
      # (Wants/After on the socket + PartOf injected onto each). Bare-string
      # form: these units run UNCONFINED (owned by signal-cli.nix) — an
      # inherited gap. Migrating them onto the confined extraServices form
      # (proton's shape below) is deferred, recorded out of scope in the
      # proton grill session (2026-07-08, decision 7).
      extraServices = lib.mkDefault [
        "spaces-signal-cli.service"
        "spaces-signal-bridge.service"
      ];
      # Post-setup restart: the MCP service ONLY — NOT spaces-signal-cli /
      # spaces-signal-bridge. The daemon already holds the freshly linked
      # account live; restarting it triggers signal-cli's per-account startup
      # network check, which silently drops the account on failure (never
      # retried), killing the link the setup flow just made.
      setupRestart = lib.mkDefault [ "spaces-integration-signal.service" ];
      # GUI QR device-linking (design §5.5): the setup helper accepts the
      # activated socket, drives the signal-cli daemon's startLink/finishLink
      # JSON-RPC, and streams qr/message/done/error events to the panel.
      setup = lib.mkDefault (lib.getExe' pkgsSelf.integration-signal "integration-signal-setup");
    };

    # Migrated from the email skill's Proton Mail recipe: Proton has no public
    # IMAP/SMTP, so the Proton Mail Bridge daemon (a CONFINED extraService below)
    # fronts it with a loopback IMAP/SMTP the generic himalaya/msmtp server talks
    # to. Read tools auto-run; message_send confirms (schema tools identical to
    # mail's). network=true so the MCP server reaches the loopback bridge (and,
    # per connectPorts, Proton's API is dialable during setup). The Bridge daemon
    # is vault-gated (inert until onboarding creates the vault); setupPark
    # displaces the single-instance daemon so the setup helper can spawn its own
    # transient --grpc Bridge. Env pinning + keychain determinism live in the
    # shared `protonmail-bridge` wrapper (../proton-bridge/wrapper.nix); the
    # spaces-proton-bridge module owns the state root + on-PATH wrapper.
    proton = mkInteg "proton" {
      description = lib.mkDefault "Proton Mail";
      network = lib.mkDefault true;
      connectPorts = lib.mkDefault [
        443
        bridgeImapPort
        bridgeSmtpPort
      ];
      autoRun = lib.mkDefault [
        "envelope_list"
        "message_read"
      ];
      # Read by the integration-proton server to locate Bridge's serving cert;
      # also consumed by the setup helper to resolve the Bridge state root.
      environment = lib.mkDefault {
        SPACES_PROTON_BRIDGE_STATE = bridgeState;
      };
      extraPaths = lib.mkDefault [
        {
          # Bridge state root — rw for the cert read + himalaya/msmtp config.
          source = bridgeState;
          mode = "rw";
        }
      ];
      # PATH-prefixed so the helper's transient `protonmail-bridge --grpc` spawn
      # resolves the env-pinning wrapper.
      setup = lib.mkDefault "${protonSetup}";
      # Single-instance Bridge: the broker parks the daemon for the setup flow so
      # the helper's transient --grpc instance can take the lock.
      setupPark = lib.mkDefault [ "spaces-proton-bridge.service" ];
      # The Bridge daemon as a full Landlock-confined resident unit: 443 egress
      # for Proton's API, binds 1143/1025 to serve loopback IMAP/SMTP, rw on its
      # own state root, vault-gated so a pre-onboarding start is inert, and
      # Restart=always (resilient companion daemon).
      extraServices = lib.mkDefault [
        {
          name = "spaces-proton-bridge.service";
          command = "${protonWrapperExe} --noninteractive";
          description = "Proton Mail Bridge (loopback IMAP/SMTP for the Proton integration)";
          network = true;
          connectPorts = [ 443 ];
          bindPorts = [
            bridgeImapPort
            bridgeSmtpPort
          ];
          extraPaths = [
            {
              source = bridgeState;
              mode = "rw";
            }
          ];
          unitConfig.ConditionPathExists = "${bridgeState}/config/protonmail/bridge-v3/vault.enc";
          restart = true;
        }
      ];
    };
  };
}
