# Cheap nix-eval contract for the hermes microvm module (specs:
# 2026-07-22-hermes-port-design.md + 2026-07-23-hermes-uid-removal-design.md):
#   - identity is a hash of the username: pinned h/CID/MAC/ports for
#     "alice" so refactors can never silently reshuffle VM identities;
#   - default-on provisioning for ALL normal users (no uid declaration
#     required), per-user opt-out, provisionNormalUsers opt-out;
#   - model-seed derivation: openrouter -> secretEnv key + initialModel null;
#     llama-swap -> seed tuple + firewall egress + seed-once preStart +
#     endpoint registered as guest providers entry;
#   - spaces bridge listens on AF_VSOCK (no host TCP port), peer-CID
#     checking helper wired with the user's CID; guest MCP dials vsock;
#   - guest runs fixed uid 1000 with runtime --translate-uid shares;
#   - firewall owner-match is by USERNAME (resolved at insert time);
#   - guard rails: settings.model and dashboardPort collisions are
#     assertion failures (checked as messages, not by building).
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  hlib = import ../../modules/nixos/hermes/lib.nix { inherit lib; };

  sys =
    mods:
    (inputs.self.lib.mkMinimalEvalSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [ inputs.self.nixosModules.hermes ] ++ mods;
    }).config;

  # NOTE: no uid anywhere — that is the point.
  alice = {
    users.users.alice = {
      isNormalUser = true;
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
  withGateway = {
    services.hermes-microvm.users.alice.spacesGateway.enable = true;
  };

  failedAssertions = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);

  # 1. openrouter brain: VM exists (uid-less user!), key injected, no
  # model seeded, gateway bridge wired over vsock.
  orSys = sys [
    alice
    on
    withOpenrouter
    withGateway
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
  orGuest = guestOf orSys "hermes-alice";
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
  portCollision = sys [
    alice
    on
    withOpenrouter
    {
      users.users.bob = {
        isNormalUser = true;
        group = "users";
      };
      # Force the collision the hash-derived defaults avoid.
      services.hermes-microvm.users.alice.dashboardPort = 22345;
      services.hermes-microvm.users.bob.dashboardPort = 22345;
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

  exchangeShare = lib.head (
    lib.filter (s: s.tag == "hermes-exchange") orGuest.microvm.shares
  );
  stateShare = lib.head (
    lib.filter (s: s.tag == "hermes-state") orGuest.microvm.shares
  );

  ok =
    # --- identity pinning: sha256-derived, must NEVER reshuffle ---
    assert hlib.identityHash "alice" == 735577801;
    assert hlib.cidFor "alice" == 735577804;
    assert hlib.spacesVsockPort "alice" == 735578825;
    assert hlib.macFor "alice" == "02:00:2b:d8:06:c9";
    assert hlib.identityHash "bob" == 2176202712;
    assert hlib.cidFor "bob" == 2176202715;
    assert hlib.guestUid == 1000;

    # --- uid-less provisioning ---
    assert builtins.attrNames orSys.microvm.vms == [ "hermes-alice" ];
    assert orSys.services.hermes-microvm.enabledUsers.alice.dashboardPort == 22901;
    assert
      orSys.services.hermes-microvm.enabledUsers.alice.secretEnv.OPENROUTER_API_KEY
      == "/run/secrets/openrouter-key";
    assert orSys.services.hermes-microvm.initialModel == null;
    assert !(lib.hasInfix ".model-seeded" orGuest.systemd.services.hermes-agent.preStart);

    # --- guest identity: fixed uid 1000, hash CID/MAC ---
    assert orGuest.users.users.alice.uid == 1000;
    assert orGuest.microvm.vsock.cid == 735577804;
    assert (lib.head orGuest.microvm.interfaces).mac == "02:00:2b:d8:06:c9";

    # --- virtiofs runtime uid translation on the two user-owned shares ---
    assert !exchangeShare.posixAcl && !stateShare.posixAcl;
    assert lib.any (a: lib.hasPrefix "map:1000:$(" a) exchangeShare.extraArgs;
    assert lib.any (a: lib.hasPrefix "map:1000:$(" a) stateShare.extraArgs;
    assert lib.elem "--xattr" exchangeShare.extraArgs;

    # --- spaces bridge: vsock listener + peer-CID helper, no TCP port ---
    assert
      orSys.systemd.sockets."hermes-spaces-bridge-alice".listenStreams
      == [ "vsock::735578825" ];
    assert lib.hasSuffix " 735577804" (
      orSys.systemd.services."hermes-spaces-bridge-alice@".serviceConfig.ExecStart
    );
    assert
      orGuest.services.hermes-agent.mcpServers.spaces.args
      == [
        "STDIO"
        "VSOCK-CONNECT:2:735578825"
      ];

    # --- dashboard forward targets the hash CID ---
    assert lib.hasInfix "VSOCK-CONNECT:735577804:" (
      orSys.systemd.services."hermes-dashboard-fwd-alice@".serviceConfig.ExecStart
    );

    # --- firewall: username owner-match, llama egress, no spaces TCP rule ---
    assert lib.hasInfix "--uid-owner alice" llamaSys.networking.firewall.extraCommands;
    assert lib.hasInfix "--dport 22901" llamaSys.networking.firewall.extraCommands;
    assert lib.hasInfix "--dport 8012 -m owner" llamaSys.networking.firewall.extraCommands;
    assert !(lib.hasInfix "22200" llamaSys.networking.firewall.extraCommands);

    # --- brain derivation (unchanged behavior) ---
    assert llamaSys.services.hermes-microvm.initialModel.base_url == "http://10.0.2.2:8012/v1";
    assert llamaSys.services.hermes-microvm.initialModel.default == "gemma4:e4b";
    assert lib.hasInfix ".model-seeded" llamaGuest.systemd.services.hermes-agent.preStart;
    assert bothSys.services.hermes-microvm.initialModel.default == "gemma4:e4b";
    assert
      bothSys.services.hermes-microvm.enabledUsers.alice.secretEnv.OPENROUTER_API_KEY
      == "/run/secrets/openrouter-key";
    assert
      llamaGuest.services.hermes-agent.settings.providers.llama-swap.base_url
      == "http://10.0.2.2:8012/v1";
    assert !(orGuest.services.hermes-agent.settings ? providers);

    assert builtins.attrNames noModelSource.microvm.vms == [ "hermes-alice" ];
    assert noModelSource.services.hermes-microvm.initialModel == null;

    assert optOutUser.microvm.vms == { };
    assert optOutAll.microvm.vms == { };

    # --- guard rails ---
    assert lib.any (m: lib.hasInfix "duplicate dashboardPort 22345" m) (
      failedAssertions portCollision
    );
    assert lib.any (m: lib.hasInfix "initialModel" m) (failedAssertions modelPin);
    true;
in
assert ok;
pkgs.runCommand "hermes-nix-eval" { } "touch $out"
