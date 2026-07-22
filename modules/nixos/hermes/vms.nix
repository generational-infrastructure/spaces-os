# VM registration: one microvm.nix guest per configured user, built from
# the per-user guest module in ./guest.nix.
#
# Double-function: `inputs` here are the PUBLISHER's (spaces') flake
# inputs, passed by default.nix — a plain `inputs` module arg would
# resolve to the consumer flake's specialArgs and miss hermes-agent.
{ inputs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hermes-microvm;
  hlib = import ./lib.nix { inherit lib; };

  # Register the local llama-swap endpoint; hermes discovers models via
  # /v1/models. Composed into cfg.settings in guest.nix.
  llamaSwapSettings =
    let
      llamaOn = config.services.llama-swap.enable or false;
      llamaPort = config.services.llama-swap.port or 8012;
    in
    lib.optionalAttrs llamaOn {
      providers.llama-swap.base_url = "http://${hlib.slirpHostAlias}:${toString llamaPort}/v1";
    };

  guestConfig = import ./guest.nix {
    inherit
      lib
      pkgs
      inputs
      hlib
      cfg
      llamaSwapSettings
      ;
  };
in
{
  config = lib.mkIf cfg.enable {
    microvm.vms = lib.mapAttrs' (
      user: ucfg:
      lib.nameValuePair (hlib.vmName user) {
        config = guestConfig user ucfg;
        # default for fully-declarative VMs; listed for greppability
        autostart = true;
      }
    ) cfg.enabledUsers;
  };
}
