# Headless test-machine VM wrapper for the agent dev loop.
#
# One-node instantiation of the shared VM driver (./lib.nix), which owns
# the repo-root state-dir discovery, ssh/wait/QMP verbs, swtpm reaping,
# and the x86_64-only stub. All state — qcow2 disk, QMP socket, serial
# console log — lives in `<repo-root>/.agent-vm/`.
#
# Typical flow:
#   agent-vm run &           # or via pueue / another terminal
#   agent-vm wait
#   agent-vm ssh systemctl --user is-active niri
#   agent-vm key alt-a
#   agent-vm screenshot /tmp/desktop.png
#   agent-vm log -f          # tail kernel/journald console
#
# x86_64-linux only — `test-machine` is x86-pinned.
{
  inputs,
  pkgs,
  ...
}:
let
  vmDriver = import ./lib.nix;
in
vmDriver.mkVmDriver {
  inherit pkgs;
  name = "agent-vm";
  nodes.machine = {
    sshPort = 2223;
    disk = "test-machine.qcow2";
    # Lazy under the non-x86 stub: mkVmDriver never forces `vm` there,
    # so evaluating on aarch64 skips the x86-pinned test-machine config.
    inherit
      ((inputs.self.nixosConfigurations.test-machine.extendModules {
        modules = [
          inputs.self.nixosModules.test-support
          { services.spaces.vm-debug.headless = true; }
        ];
      }).config.system.build
      )
      vm
      ;
  };
}
