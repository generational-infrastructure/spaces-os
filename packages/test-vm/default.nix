# Builds the test-machine QEMU VM.
# Run: nix build .#test-vm && ./result/bin/run-test-machine-vm
#  or: nix run .#test-vm
#
# The QEMU disk image lands at <repo>/.agent-vm/test-vm.qcow2 (gitignored),
# not in the cwd — same workdir as the headless agent-vm, distinct filename.
#
# OpenRouter: if $OPENROUTER_API_KEY is set in your shell, the launcher
# forwards it into the guest at boot via QEMU fw_cfg (no --impure, key
# never enters the store) — the guest stages it for pi-sessiond so
# OpenRouter's models appear in the panel picker. See
# hosts/test-machine/openrouter.nix. (`nix run --impure .#test-vm`
# additionally makes OpenRouter the default provider.)
#
# x86_64-linux only — `test-machine` is x86_64-pinned. On other
# build systems we ship a stub that explains the situation when
# `run-test-machine-vm` is invoked. Lets `nix flake check` succeed
# on aarch64 without forcing a cross-build of the x86 VM.
{ inputs, pkgs, ... }:
if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then
  let
    inherit (inputs.self.nixosConfigurations.test-machine.config.system.build) vm;
  in
  # Thin launcher around the generated VM runner: publish the host's
  # OpenRouter key over fw_cfg when present, then run the VM. Keeping the
  # binary name `run-test-machine-vm` preserves both `nix run .#test-vm`
  # and `./result/bin/run-test-machine-vm`.
  pkgs.writeShellApplication {
    name = "run-test-machine-vm";
    runtimeInputs = [
      pkgs.coreutils
      # pgrep, for the stale-swtpm reaper below.
      pkgs.procps
      # remote-viewer: the SPICE client the launcher spawns for the
      # interactive display (see the spice wiring in vm-debug.nix).
      pkgs.virt-viewer
    ];
    text = ''
      # Keep QEMU's disk image out of the repo root. Resolve the repo
      # root (closest ancestor with .jj/.git, else $PWD) the same way the
      # headless agent-vm wrapper does and stash the qcow2 under
      # <repo>/.agent-vm/. A distinct name (test-vm.qcow2 vs the headless
      # agent-vm's test-machine.qcow2) keeps the two runnable side by side.
      state_dir=$PWD/.agent-vm
      d=$PWD
      while [ "$d" != / ]; do
        if [ -d "$d/.jj" ] || [ -d "$d/.git" ]; then
          state_dir="$d/.agent-vm"
          break
        fi
        d=$(dirname "$d")
      done
      mkdir -p -- "$state_dir"
      export NIX_DISK_IMAGE="$state_dir/test-vm.qcow2"
      ${builtins.readFile ../agent-vm/reap-swtpm.sh}
      # The runner resolves NIX_SWTPM_DIR relative to $PWD (default
      # test-machine-swtpm) and its swtpm daemon can outlive a hard-killed
      # QEMU, wedging every later launch on the TPM state lock. Reap any
      # orphan first; abort if that swtpm still serves a live VM.
      reap_swtpm "''${NIX_SWTPM_DIR:-test-machine-swtpm}"

      # One EXIT trap for everything: temp files to delete and the SPICE
      # client to reap. A second `trap … EXIT` would clobber the first,
      # so both the OpenRouter keyfile and the viewer register here.
      cleanup_files=()
      viewer_pid=""
      cleanup() {
        if [ -n "$viewer_pid" ]; then
          kill "$viewer_pid" 2>/dev/null || true
        fi
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

      # The guest opts (modules/nixos/vm-debug.nix) render the display to
      # a SPICE unix socket rather than a local QEMU window, so the
      # host<->guest clipboard works (QEMU's GTK clipboard bridge ships
      # disabled in nixpkgs). Publish the socket path the guest opts read,
      # then spawn the client once QEMU has created it. The wait loop
      # covers the socket not existing yet at launch.
      sockdir="''${XDG_RUNTIME_DIR:-/tmp}"
      TEST_VM_SPICE_SOCK="$sockdir/test-vm-spice.sock"
      export TEST_VM_SPICE_SOCK
      rm -f "$TEST_VM_SPICE_SOCK"
      cleanup_files+=("$TEST_VM_SPICE_SOCK")
      (
        tries=0
        while [ ! -S "$TEST_VM_SPICE_SOCK" ] && [ "$tries" -lt 300 ]; do
          sleep 0.1
          tries=$((tries + 1))
        done
        exec remote-viewer "spice+unix://$TEST_VM_SPICE_SOCK"
      ) &
      viewer_pid=$!

      # No exec: keep the shell alive so the trap cleans up (keyfile,
      # socket, viewer) after QEMU exits — QEMU has already read fw_cfg
      # by then.
      ${vm}/bin/run-test-machine-vm "$@"
    '';
  }
else
  pkgs.runCommand "test-vm-x86_64-only" { } ''
    mkdir -p "$out/bin"
    cat > "$out/bin/run-test-machine-vm" <<'EOF'
    #!/bin/sh
    echo "test-vm is x86_64-linux only; no aarch64 test-machine host yet." >&2
    exit 1
    EOF
    chmod +x "$out/bin/run-test-machine-vm"
  ''
