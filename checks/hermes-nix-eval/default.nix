# Cheap nix-eval contract for the hermes microvm module's productized
# behavior (docs/superpowers/specs/2026-07-22-hermes-port-design.md):
#   - default-on provisioning for uid-declared normal users, per-user
#     opt-out, provisionNormalUsers opt-out;
#   - no configured model source still provisions (initialModel null);
#   - model-seed derivation: openrouter -> secretEnv key + initialModel null;
#     llama-swap -> seed tuple + firewall egress + seed-once preStart +
#     endpoint registered as guest providers entry;
#   - guard rails: settings.model and uid-less users are assertion
#     failures (checked as failed assertion messages, not by building).
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;

  sys =
    mods:
    (inputs.self.lib.mkMinimalEvalSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [ inputs.self.nixosModules.hermes ] ++ mods;
    }).config;

  alice = {
    users.users.alice = {
      isNormalUser = true;
      uid = 1000;
      group = "users";
    };
  };
  on = {
    services.hermes-microvm.enable = true;
  };
  withOpenrouter = {
    spaces.openrouter = {
      enable = true;
      apiKeyFile = "/run/secrets/openrouter-key";
    };
  };

  failedAssertions = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);

  # 1. openrouter brain: VM exists, key injected, no model seeded.
  orSys = sys [
    alice
    on
    withOpenrouter
  ];
  # 2. llama-swap: seed tuple, firewall egress, providers entry.
  llamaSys = sys [
    alice
    on
    inputs.self.nixosModules.llama-swap
    { services.llama-swap.enable = true; }
    # Reads networking.firewall.extraCommands back — pull the declaring
    # modules in (mkMinimalEvalSystem carries only the common surface).
    (inputs.nixpkgs + "/nixos/modules/services/networking/firewall.nix")
    (inputs.nixpkgs + "/nixos/modules/services/networking/firewall-iptables.nix")
    # llama-swap.nix branches on networking.nftables.enable.
    (inputs.nixpkgs + "/nixos/modules/services/networking/nftables.nix")
  ];
  guestOf = cfg: name: cfg.microvm.vms.${name}.config.config;
  llamaGuest = guestOf llamaSys "hermes-alice";
  # 3. no configured model source: VM still provisioned, initialModel null.
  noModelSource = sys [
    alice
    on
  ];
  # 4. opt-outs.
  optOutUser = sys [
    alice
    on
    withOpenrouter
    { services.hermes-microvm.users.alice.enable = false; }
  ];
  optOutAll = sys [
    alice
    on
    withOpenrouter
    { services.hermes-microvm.provisionNormalUsers = false; }
  ];
  # 5. guard rails (eval assertions, never built).
  uidless = sys [
    on
    withOpenrouter
    {
      users.users.bob = {
        isNormalUser = true;
        group = "users";
      };
    }
  ];
  modelPin = sys [
    alice
    on
    withOpenrouter
    { services.hermes-microvm.settings.model = "openrouter/foo"; }
  ];
  # 6. openrouter + llama both on: llama wins the seed (deterministic,
  # offline); openrouter still available via .env key + providers entry.
  bothSys = sys [
    alice
    on
    withOpenrouter
    inputs.self.nixosModules.llama-swap
    { services.llama-swap.enable = true; }
    (inputs.nixpkgs + "/nixos/modules/services/networking/firewall.nix")
    (inputs.nixpkgs + "/nixos/modules/services/networking/firewall-iptables.nix")
    (inputs.nixpkgs + "/nixos/modules/services/networking/nftables.nix")
  ];

  ok =
    assert builtins.attrNames orSys.microvm.vms == [ "hermes-alice" ];
    assert
      orSys.services.hermes-microvm.enabledUsers.alice.secretEnv.OPENROUTER_API_KEY
      == "/run/secrets/openrouter-key";
    assert orSys.services.hermes-microvm.initialModel == null;
    assert
      !(lib.hasInfix ".model-seeded" (guestOf orSys "hermes-alice")
      .systemd.services.hermes-agent.preStart);

    assert llamaSys.services.hermes-microvm.initialModel.base_url == "http://10.0.2.2:8012/v1";
    assert llamaSys.services.hermes-microvm.initialModel.default == "gemma4:e4b";
    assert lib.hasInfix ".model-seeded" llamaGuest.systemd.services.hermes-agent.preStart;
    assert lib.hasInfix "--dport 8012 -m owner" llamaSys.networking.firewall.extraCommands;

    # Both on: llama wins the seed; openrouter key still injected.
    assert bothSys.services.hermes-microvm.initialModel.default == "gemma4:e4b";
    assert
      bothSys.services.hermes-microvm.enabledUsers.alice.secretEnv.OPENROUTER_API_KEY
      == "/run/secrets/openrouter-key";
    # llama-swap endpoint registered; hermes discovers models via /v1/models.
    assert
      llamaGuest.services.hermes-agent.settings.providers.llama-swap.base_url
      == "http://10.0.2.2:8012/v1";
    # No llama-swap on the openrouter host -> no providers block.
    assert !((guestOf orSys "hermes-alice").services.hermes-agent.settings ? providers);

    assert builtins.attrNames noModelSource.microvm.vms == [ "hermes-alice" ];
    assert noModelSource.services.hermes-microvm.initialModel == null;

    assert optOutUser.microvm.vms == { };
    assert optOutAll.microvm.vms == { };

    assert lib.any (m: lib.hasInfix "users.bob: no uid" m) (failedAssertions uidless);
    assert lib.any (m: lib.hasInfix "initialModel" m) (failedAssertions modelPin);
    true;
in
assert ok;
pkgs.runCommand "hermes-nix-eval" { } "touch $out"
