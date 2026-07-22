# Full-boot hermes microvm test: desktop-role provisioning (default-on,
# auto-provisioned uid-1000 user), the vsock ssh shim, the dashboard
# forward socket, and the guest python venv contract — all against the
# REAL guest booted inside the test VM.
#
# Nested virtualization: the inner qemu falls back to TCG without
# nested KVM; allow several minutes. Deliberately NOT the full
# nixosModules.spaces desktop (voxtype's ASR closure and greetd add
# gigabytes and minutes for zero hermes coverage).
{ pkgs, inputs, ... }:
pkgs.testers.runNixOSTest {
  name = "hermes-vm";

  nodes.machine = {
    imports = [
      inputs.self.nixosModules.hermes
      inputs.self.nixosModules.openrouter
    ];
    virtualisation.cores = 4;
    virtualisation.memorySize = 6144;
    virtualisation.diskSize = 16 * 1024;

    users.users.alice = {
      isNormalUser = true;
      uid = 1000;
      group = "users";
    };

    services.hermes-microvm.enable = true;
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

    # Auto-provisioned VM comes up (TCG: generous timeout).
    machine.wait_for_unit("microvm@hermes-alice.service", timeout=300)

    # Guest sshd reachable over vsock: exercise the REAL `hermes` shim
    # path end to end. The shim needs a login-ish environment.
    machine.wait_until_succeeds(
        "runuser -u alice -- hermes --version",
        timeout=1200,
    )

    # Dashboard forward socket is bound (root-held, squat-proof).
    machine.succeed("systemctl is-active hermes-dashboard-fwd-alice.socket")

    # Guest python contract (old guest-python-test, against the real
    # guest): ssh through the same vsock route the shim uses.
    ssh = (
        "runuser -u alice -- ssh -q"
        " -i /var/lib/hermes-microvm/alice/ssh/client_ed25519"
        " -o UserKnownHostsFile=/var/lib/hermes-microvm/alice/ssh/known_hosts"
        " -o StrictHostKeyChecking=yes -o HostKeyAlias=hermes-alice"
        " -o ProxyCommand='${pkgs.systemd}/lib/systemd/systemd-ssh-proxy vsock/1000 22'"
        " -o ProxyUseFdpass=yes -o ControlMaster=no -o ControlPath=none"
        " alice@hermes-alice -- "
    )
    def guest(cmd):
        # Two quoting layers: the host shell (machine.succeed) and the
        # guest-side login shell sshd spawns for the remote command.
        return machine.succeed(ssh + shlex.quote("bash -lc " + shlex.quote(cmd)))

    # First boot builds the venv (pip-installs the whole pythonPackages
    # set) — wait for it before asserting the PATH contract.
    machine.wait_until_succeeds(
        ssh + "'systemctl is-active --quiet hermes-python-venv.service'",
        timeout=1200,
    )

    # 1. venv python/pip first on PATH for login shells
    assert "/var/lib/hermes/.venv/bin/python3" in guest("command -v python3")
    assert "/var/lib/hermes/.venv/bin/pip" in guest("command -v pip")
    # 2. pip can install into the venv (offline wheel: pure-python stdlib shim)
    guest("pip install --no-index --no-deps --quiet --dry-run pip")
    # 3. model was NOT seeded (openrouter brain: credentials only)
    machine.succeed(ssh + "'! test -e /var/lib/hermes/.hermes/.model-seeded'")
    # 4. credentials landed in the state .env
    guest("grep -q OPENROUTER_API_KEY /var/lib/hermes/.hermes/.env")
  '';
}
