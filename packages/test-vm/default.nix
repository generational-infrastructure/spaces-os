# Builds the test-machine QEMU VM.
# Run: nix build .#test-vm && ./result/bin/run-test-machine-vm
#  or: nix run .#test-vm
#
# GUI-mode instantiation of the shared VM driver (../agent-vm/lib.nix,
# launcher mode): no verbs, argv passes straight to QEMU's runner. The
# driver owns the repo-root discovery and stale-swtpm reaping; the disk
# image lands at <repo>/.agent-vm/test-vm.qcow2 (gitignored) — same
# workdir as the headless agent-vm, distinct filename, so the two stay
# runnable side by side.
#
# OpenRouter: if $OPENROUTER_API_KEY is set in your shell, the launcher
# forwards it into the guest at boot via QEMU fw_cfg (no --impure, key
# never enters the store) — the guest stages it for pi-sessiond so
# OpenRouter's models appear in the panel picker. See
# hosts/test-machine/openrouter.nix. (`nix run --impure .#test-vm`
# additionally makes OpenRouter the default provider.)
#
# x86_64-linux only — `test-machine` is x86_64-pinned; the driver ships
# an explanatory stub elsewhere so `nix flake check` succeeds on aarch64.
{ inputs, pkgs, ... }:
let
  vmDriver = import ../agent-vm/lib.nix;
in
vmDriver.mkVmDriver {
  inherit pkgs;
  # Keeping the binary name `run-test-machine-vm` preserves both
  # `nix run .#test-vm` and `./result/bin/run-test-machine-vm`.
  name = "run-test-machine-vm";
  stubName = "test-vm";
  stateDirName = ".agent-vm";
  launcher = true;
  nodes.machine = {
    vm = inputs.self.nixosConfigurations.test-machine.config.system.build.vm;
    disk = "test-vm.qcow2";
  };
  preRun = ''
    # One EXIT trap: the OpenRouter keyfile. (The display is QEMU's own
    # GTK window - see vm-debug.nix - so there is no viewer process
    # or SPICE socket left to reap.)
    cleanup_files=()
    cleanup() {
      if [ "''${#cleanup_files[@]}" -gt 0 ]; then
        rm -f "''${cleanup_files[@]}"
      fi
    }
    trap cleanup EXIT

    if [ -n "''${OPENROUTER_API_KEY:-}" ]; then
      # A 0600 file (not -fw_cfg string=) keeps the key out of `ps`.
      # Prefer the user runtime dir (0700) over /tmp.
      keydir="''${XDG_RUNTIME_DIR:-/tmp}"
      keyfile="$(mktemp "$keydir/openrouter-key.XXXXXX")"
      chmod 600 "$keyfile"
      cleanup_files+=("$keyfile")
      printf '%s' "$OPENROUTER_API_KEY" > "$keyfile"
      QEMU_OPTS="''${QEMU_OPTS:-} -fw_cfg name=opt/org.spaces/openrouter-key,file=$keyfile"
      export QEMU_OPTS
    fi
  '';
}
