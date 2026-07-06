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
    };
  };
}
