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
in
{
  services.spaces-integrations.integrations = {
    github = {
      description = lib.mkDefault "GitHub";
      command = lib.mkDefault (exe "integration-github");
      network = lib.mkDefault true;
      connectPorts = lib.mkDefault [ 443 ];
      config = lib.mkDefault (configOf "github");
      secrets = lib.mkDefault (secretsOf "github");
      autoRun = lib.mkDefault [ "get_repo" ];
    };

    # Migrated from the calendar skill: CalDAV over the panel-provisioned,
    # host+tpm2-sealed store. Read tools auto-run; writes confirm per call.
    caldav = {
      description = lib.mkDefault "Calendar (CalDAV)";
      command = lib.mkDefault (exe "integration-caldav");
      network = lib.mkDefault true;
      connectPorts = lib.mkDefault [ 443 ];
      multiProfile = lib.mkDefault true;
      config = lib.mkDefault (configOf "caldav");
      secrets = lib.mkDefault (secretsOf "caldav");
      autoRun = lib.mkDefault [
        "list"
        "get"
        "etag"
      ];
    };

    # Migrated from the contacts skill: CardDAV.
    contacts = {
      description = lib.mkDefault "Contacts (CardDAV)";
      command = lib.mkDefault (exe "integration-contacts");
      network = lib.mkDefault true;
      connectPorts = lib.mkDefault [ 443 ];
      multiProfile = lib.mkDefault true;
      config = lib.mkDefault (configOf "contacts");
      secrets = lib.mkDefault (secretsOf "contacts");
      autoRun = lib.mkDefault [
        "discover"
        "search"
        "get"
      ];
    };

    # Migrated from the email skill: IMAP/SMTP via himalaya. send confirms.
    mail = {
      description = lib.mkDefault "Email (IMAP/SMTP)";
      command = lib.mkDefault (exe "integration-mail");
      network = lib.mkDefault true;
      connectPorts = lib.mkDefault [
        993
        587
        465
        143
        25
      ];
      multiProfile = lib.mkDefault true;
      config = lib.mkDefault (configOf "mail");
      secrets = lib.mkDefault (secretsOf "mail");
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
    signal = {
      description = lib.mkDefault "Signal";
      command = lib.mkDefault (exe "integration-signal");
      network = lib.mkDefault false;
      connectPorts = lib.mkDefault [ ];
      config = lib.mkDefault (configOf "signal");
      secrets = lib.mkDefault (secretsOf "signal");
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
      # (Wants/After on the socket + PartOf injected onto each).
      extraServices = lib.mkDefault [
        "spaces-signal-cli.service"
        "spaces-signal-bridge.service"
      ];
      # GUI QR device-linking (design §5.5): the setup helper accepts the
      # activated socket, drives the signal-cli daemon's startLink/finishLink
      # JSON-RPC, and streams qr/message/done/error events to the panel.
      setup = lib.mkDefault (lib.getExe' pkgsSelf.integration-signal "integration-signal-setup");
    };
  };
}
