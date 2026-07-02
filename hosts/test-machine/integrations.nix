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
{
  inputs,
  pkgs,
  lib,
  ...
}:
let
  pkgsSelf = inputs.self.packages.${pkgs.stdenv.hostPlatform.system};
  exe = name: lib.getExe pkgsSelf.${name};
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
        secrets.token.description = "GitHub personal access token (repo scope)";
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
        config = {
          url.description = "Full CalDAV collection URL";
          user.description = "CalDAV username";
        };
        secrets.password.description = "CalDAV password";
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
        config = {
          server.description = "CardDAV addressbook collection URL";
          user.description = "CardDAV username";
          book = {
            description = "Addressbook path (optional)";
            required = false;
          };
        };
        secrets.password.description = "CardDAV password";
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
        config = {
          email.description = "Email address of the account";
          imap_host.description = "IMAP server hostname";
          smtp_host.description = "SMTP server hostname";
          imap_port = {
            description = "IMAP server port (default 993)";
            required = false;
          };
          smtp_port = {
            description = "SMTP server port (default 587)";
            required = false;
          };
          imap_login = {
            description = "IMAP login (default: email)";
            required = false;
          };
          smtp_login = {
            description = "SMTP login (default: email)";
            required = false;
          };
          imap_encryption = {
            description = "IMAP encryption: tls, start-tls or none (default: by port)";
            required = false;
          };
          smtp_encryption = {
            description = "SMTP encryption: tls, start-tls or none (default: by port)";
            required = false;
          };
          display_name = {
            description = "Sender display name";
            required = false;
          };
        };
        secrets.password.description = "Mailbox password";
        autoRun = [
          "envelope_list"
          "message_read"
        ];
      };
    };
  };
}
