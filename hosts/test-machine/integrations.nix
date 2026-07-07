# Agent integrations for the test-machine: declare the GitHub integration for
# the whole host — the real machine, the interactive `nix run .#test-vm`, and
# the checks/test-machine.nix round-trip nodes alike.
#
# The spaces-integrations module (bundled + enabled by pi-chat, via
# modules/nixos/spaces.nix) owns its prerequisites: `security.tpm2` + a software
# TPM for VM builds (the broker seals the token with `host+tpm2`), and it grants
# every normal user `tss`. So declaring an integration needs no host boilerplate.
#
# GitHub points at the real api.github.com; provision your own PAT from the
# panel (sealed into the user credstore, never the Nix store), and
# `connectPorts = [ 443 ]` is its Landlock egress. It is inert until enabled:
# the socket unit has no wantedBy, the broker only starts it once a secret is
# set, and daemon discovery skips it until then — so the offline round-trip
# check carries it as a dormant unit and never touches the network. For an
# offline *functional* test, point SPACES_GITHUB_API_URL at a mock instead (see
# checks/integration-poc-machine for the pattern).
#
# Each integration's config/secrets field schema is single-sourced from the
# schema.json its package ships next to the server module (pure eval, no
# build); checks/spaces-integrations-schema-sync pins the manifest against it.
{
  inputs,
  pkgs,
  lib,
  ...
}:
let
  pkgsSelf = inputs.self.packages.${pkgs.stdenv.hostPlatform.system};
  exe = name: lib.getExe pkgsSelf.${name};
  # The package's exported store contract: { config, secrets, tools }.
  schemaOf =
    name: builtins.fromJSON (builtins.readFile (../../packages + "/integration-${name}/schema.json"));
  fieldsOf = name: { inherit (schemaOf name) config secrets; };
in
{
  services.spaces-integrations = {
    enable = true;
    integrations = {
      github = {
        description = "GitHub";
        command = exe "integration-github";
        network = true;
        connectPorts = [ 443 ];
        inherit (fieldsOf "github") config secrets;
        autoRun = [ "get_repo" ];
      };

      # Migrated from the calendar skill: CalDAV over the panel-provisioned,
      # host+tpm2-sealed store. Read tools auto-run; writes confirm per call.
      caldav = {
        description = "Calendar (CalDAV)";
        command = exe "integration-caldav";
        network = true;
        connectPorts = [ 443 ];
        multiProfile = true;
        inherit (fieldsOf "caldav") config secrets;
        autoRun = [
          "list"
          "get"
          "etag"
        ];
      };

      # Migrated from the contacts skill: CardDAV.
      contacts = {
        description = "Contacts (CardDAV)";
        command = exe "integration-contacts";
        network = true;
        connectPorts = [ 443 ];
        multiProfile = true;
        inherit (fieldsOf "contacts") config secrets;
        autoRun = [
          "discover"
          "search"
          "get"
        ];
      };

      # Migrated from the email skill: IMAP/SMTP via himalaya. send confirms.
      mail = {
        description = "Email (IMAP/SMTP)";
        command = exe "integration-mail";
        network = true;
        connectPorts = [
          993
          587
          465
          143
          25
        ];
        multiProfile = true;
        inherit (fieldsOf "mail") config secrets;
        autoRun = [
          "envelope_list"
          "message_read"
        ];
      };

      # Migrated from the signal skill: the signal-cli daemon over the
      # panel-enabled, field-less store (no config/secrets — linking is the
      # out-of-band `signal-cli link` QR flow). Read/list tools auto-run;
      # `send` confirms with a rendered `send_preview`. No network: the
      # signal-cli daemon owns the internet, so the integration only reaches
      # the daemon socket + the local message store granted via extraPaths.
      signal = {
        description = "Signal";
        command = exe "integration-signal";
        network = false;
        connectPorts = [ ];
        inherit (fieldsOf "signal") config secrets;
        autoRun = [
          "threads"
          "read_thread"
          "search"
          "contacts"
          "groups"
          "note_to_self"
          "fetch_attachment"
        ];
        confirmPreview.send = "send_preview";
        # The server reads these at start (integration_signal.py); values carry
        # systemd %t/%h specifiers, resolved identically to the extraPaths grants.
        environment = {
          SPACES_SIGNAL_DAEMON_SOCKET = "%t/signal-cli/socket";
          SPACES_SIGNAL_ATTACHMENTS_DIR = "%h/.local/share/signal-cli/attachments";
          SPACES_SIGNAL_DB = "%h/.local/state/spaces/signal/messages.db";
        };
        extraPaths = [
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
      };
    };
  };
}
