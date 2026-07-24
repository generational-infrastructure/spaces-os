# Full-boot hermes microvm test: desktop-role provisioning of TWO
# uid-less users (identity never needs a declared uid), the
# vsock ssh shim, the dashboard forward socket, runtime virtiofs uid
# translation (guest 1000 <-> runtime host uid), and the vsock spaces
# bridge incl. its peer-CID gate (bob's VM must NOT reach alice's
# gateway) — all against REAL guests booted inside the test VM.
#
# Nested virtualization: the inner qemus fall back to TCG without
# nested KVM; two guests — allow many minutes. Deliberately NOT the
# full nixosModules.spaces desktop (voxtype's ASR closure and greetd
# add gigabytes and minutes for zero hermes coverage).
{ pkgs, inputs, ... }:
let
  lib = inputs.nixpkgs.lib;
  hlib = import ../modules/nixos/hermes/lib.nix { inherit lib; };
  aliceCid = toString (hlib.cidFor "alice");
  bobCid = toString (hlib.cidFor "bob");
  alicePort = toString (hlib.spacesVsockPort "alice");
  aliceDashPort = toString (22100 + lib.mod (hlib.identityHash "alice") 1000);
in
pkgs.testers.runNixOSTest {
  name = "hermes-vm";

  nodes.machine = {
    imports = [
      inputs.self.nixosModules.hermes
      inputs.self.nixosModules.openrouter
    ];
    virtualisation.cores = 4;
    virtualisation.memorySize = 8192;
    virtualisation.diskSize = 24 * 1024;

    # NO uid declarations: identity must not need them.
    users.users.alice = {
      isNormalUser = true;
      group = "users";
    };
    users.users.bob = {
      isNormalUser = true;
      group = "users";
    };

    services.hermes-microvm.enable = true;
    # Exercise the bridge + peer-CID gate without the real integration
    # gateway: enable the bridge for alice only; the test starts a fake
    # echo gateway at the default (runtime-resolved) socket path.
    services.hermes-microvm.users.alice.spacesGateway.enable = true;
    # Dummy key: exercises the OPENROUTER_API_KEY credential-injection
    # path (asserted in .env below); the gateway starts fine with a
    # bogus key (model resolution is per-message).
    spaces.openrouter = {
      enable = true;
      apiKeyFile = pkgs.writeText "openrouter-key" "sk-or-dummy";
    };
  };

  testScript = ''
    import shlex

    machine.start()
    machine.wait_for_unit("multi-user.target")

    # Both auto-provisioned VMs come up (TCG: generous timeouts).
    machine.wait_for_unit("microvm@hermes-alice.service", timeout=600)
    machine.wait_for_unit("microvm@hermes-bob.service", timeout=600)

    # Guest sshd reachable over vsock: exercise the REAL `hermes` shim
    # path end to end (shim resolves the hash CID internally).
    machine.wait_until_succeeds(
        "runuser -u alice -- hermes --version",
        timeout=2400,
    )

    # Dashboard forward socket is bound (root-held, squat-proof).
    machine.succeed("systemctl is-active hermes-dashboard-fwd-alice.socket")
    # Spaces bridge socket is AF_VSOCK, not TCP.
    machine.succeed("systemctl is-active hermes-spaces-bridge-alice.socket")
    out = machine.succeed("systemctl show -p Listen hermes-spaces-bridge-alice.socket")
    assert "vsock::${alicePort}" in out, f"bridge not on vsock: {out}"

    with subtest("dashboard forward is owner-gated (firewall username match)"):
        # firewall.service parsed the --uid-owner USERNAME rules — i.e.
        # it started after userborn created the users (After= edge).
        machine.succeed("systemctl is-active firewall.service")
        connect = "'exec 3<>/dev/tcp/127.0.0.1/${aliceDashPort}'"
        # Owner: the root-held socket accepts (regardless of guest
        # dashboard state). Non-owner: REJECT tcp-reset -> ECONNREFUSED.
        machine.succeed(f"runuser -u alice -- bash -c {connect}")
        machine.fail(f"runuser -u bob -- bash -c {connect}")

    def mk_ssh(user, cid):
        return (
            f"runuser -u {user} -- ssh -q"
            f" -i /var/lib/hermes-microvm/{user}/ssh/client_ed25519"
            f" -o UserKnownHostsFile=/var/lib/hermes-microvm/{user}/ssh/known_hosts"
            f" -o StrictHostKeyChecking=yes -o HostKeyAlias=hermes-{user}"
            f" -o ProxyCommand='${pkgs.systemd}/lib/systemd/systemd-ssh-proxy vsock/{cid} 22'"
            " -o ProxyUseFdpass=yes -o ControlMaster=no -o ControlPath=none"
            f" {user}@hermes-{user} -- "
        )

    ssh = mk_ssh("alice", "${aliceCid}")
    ssh_bob = mk_ssh("bob", "${bobCid}")

    def guest(cmd):
        # Two quoting layers: the host shell (machine.succeed) and the
        # guest-side login shell sshd spawns for the remote command.
        return machine.succeed(ssh + shlex.quote("bash -lc " + shlex.quote(cmd)))

    def guest_bob(cmd):
        return machine.succeed(ssh_bob + shlex.quote("bash -lc " + shlex.quote(cmd)))

    # First boot builds the venv (pip-installs the whole pythonPackages
    # set) — wait for it before asserting the PATH contract.
    machine.wait_until_succeeds(
        ssh + "'systemctl is-active --quiet hermes-python-venv.service'",
        timeout=2400,
    )

    with subtest("guest python contract"):
        assert "/var/lib/hermes/.venv/bin/python3" in guest("command -v python3")
        assert "/var/lib/hermes/.venv/bin/pip" in guest("command -v pip")
        guest("pip install --no-index --no-deps --quiet --dry-run pip")

    with subtest("brain: credentials only, never a model pin"):
        machine.succeed(ssh + "'! test -e /var/lib/hermes/.hermes/.model-seeded'")
        guest("grep -q OPENROUTER_API_KEY /var/lib/hermes/.hermes/.env")

    with subtest("virtiofs uid translation: guest 1000 <-> runtime host uid"):
        alice_uid = machine.succeed("id -u alice").strip()
        # guest side: the account is uid 1000 and owns its HOME
        assert guest("id -u").strip() == "1000"
        # NOTE: guest HOME *is* the exchange dir (/home/alice/hermes),
        # so the marker lands at ~/xfer-marker = host /home/alice/hermes/….
        guest("touch ~/xfer-marker")
        assert guest("stat -c %u ~/xfer-marker").strip() == "1000"
        # host side: the same file belongs to the RUNTIME host uid
        host_owner = machine.succeed("stat -c %u /home/alice/hermes/xfer-marker").strip()
        assert host_owner == alice_uid, f"host owner {host_owner}, want {alice_uid}"

    with subtest("spaces bridge: own VM passes the peer-CID gate"):
        # Fake gateway at the DEFAULT (runtime-resolved) socket path —
        # linger (from spacesGateway.enable) already runs alice's user
        # manager, so /run/user/<uid> exists.
        alice_uid = machine.succeed("id -u alice").strip()
        machine.succeed(
            "systemd-run --uid=alice --unit=fake-gw -- ${pkgs.socat}/bin/socat"
            f" UNIX-LISTEN:/run/user/{alice_uid}/spaces-integration-gateway.sock,fork"
            " EXEC:'${pkgs.coreutils}/bin/cat'"
        )
        machine.wait_until_succeeds(
            f"test -S /run/user/{alice_uid}/spaces-integration-gateway.sock",
            timeout=30,
        )
        echoed = guest(
            "printf ping | socat -T 10 STDIO VSOCK-CONNECT:2:${alicePort}"
        )
        assert "ping" in echoed, f"bridge echo failed: {echoed!r}"

    with subtest("spaces bridge: sibling VM is rejected at accept"):
        # bob's guest dials alice's bridge port: helper sees peer CID
        # ${bobCid} != ${aliceCid} and closes without a byte.
        out = guest_bob(
            "printf ping | socat -T 10 STDIO VSOCK-CONNECT:2:${alicePort} 2>&1 || true"
        )
        assert "ping" not in out, f"cross-VM bridge leak: {out!r}"
        # wait_until_succeeds: the per-connection instance exits within
        # milliseconds; give journald time to attribute the stream.
        machine.wait_until_succeeds(
            "journalctl -u 'hermes-spaces-bridge-alice@*' | grep -q 'rejecting connection: peer cid ${bobCid}'",
            timeout=30,
        )
  '';
}
