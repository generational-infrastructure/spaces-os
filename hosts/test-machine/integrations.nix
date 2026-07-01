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
{
  services.spaces-integrations = {
    enable = true;
    integrations.github = {
      description = "GitHub";
      command = lib.getExe inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.integration-github;
      network = true;
      connectPorts = [ 443 ];
      secrets.token.description = "GitHub personal access token (repo scope)";
      autoRun = [ "get_repo" ];
    };
  };
}
