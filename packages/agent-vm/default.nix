# Headless test-machine VM wrapper for the agent dev loop.
#
# All state — qcow2 disk, QMP socket, serial console log — lives in
# `<repo-root>/.agent-vm/` (the closest ancestor of $PWD that contains
# `.jj` or `.git`, falling back to $PWD). Every subcommand resolves
# this the same way, so you can invoke `agent-vm` from any subdir.
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
if pkgs.stdenv.hostPlatform.system != "x86_64-linux" then
  pkgs.runCommand "agent-vm-x86_64-only" { } ''
    mkdir -p "$out/bin"
    cat > "$out/bin/agent-vm" <<'EOF'
    #!/bin/sh
    echo "agent-vm is x86_64-linux only; no aarch64 test-machine host yet." >&2
    exit 1
    EOF
    chmod +x "$out/bin/agent-vm"
  ''
else
  let
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
  in
  pkgs.writeShellApplication {
    name = "agent-vm";
    runtimeInputs = [
      vm
      pkgs.openssh
      pkgs.sshpass
      pkgs.python3
      pkgs.coreutils
      # pgrep, for the stale-swtpm reaper below.
      pkgs.procps
    ];
    text = ''
      # Locate the repo root so state is the same regardless of cwd.
      state_dir=$PWD/.agent-vm
      d=$PWD
      while [ "$d" != / ]; do
        if [ -d "$d/.jj" ] || [ -d "$d/.git" ]; then
          state_dir="$d/.agent-vm"
          break
        fi
        d=$(dirname "$d")
      done
      qmp="$state_dir/qmp.sock"
      serial="$state_dir/serial.log"

      ${builtins.readFile ./reap-swtpm.sh}

      ssh_args=(
        -p 2223
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
      )

      cmd="''${1:-help}"
      if [ "$#" -gt 0 ]; then shift; fi

      case "$cmd" in
        run)
          mkdir -p -- "$state_dir"
          rm -f -- "$qmp"
          : >"$serial"
          echo "agent-vm: state at $state_dir (serial: $serial)"
          cd "$state_dir"
          # The qemu-vm runner resolves NIX_SWTPM_DIR relative to $PWD
          # (default test-machine-swtpm — here, under $state_dir thanks to
          # the cd above) and its swtpm daemon can outlive a hard-killed
          # QEMU (pueue kill, dropped terminal), wedging every later launch
          # on the TPM state lock. Reap any orphan first; abort if that
          # swtpm still serves a live VM.
          reap_swtpm "''${NIX_SWTPM_DIR:-test-machine-swtpm}"
          export AGENT_VM_QMP="$qmp"
          export AGENT_VM_SERIAL="$serial"
          export NIX_DISK_IMAGE="$state_dir/test-machine.qcow2"
          # loglevel=7 so kernel boot info reaches the serial log;
          # the test-machine baseline has loglevel=4 (warnings only).
          export QEMU_KERNEL_PARAMS="''${QEMU_KERNEL_PARAMS:-} loglevel=7"
          exec run-test-machine-vm
          ;;

        ssh)
          export SSHPASS=test
          exec sshpass -e ssh "''${ssh_args[@]}" test@localhost "$@"
          ;;

        wait)
          timeout="''${1:-120}"
          deadline=$(( $(date +%s) + timeout ))
          export SSHPASS=test
          while [ "$(date +%s)" -lt "$deadline" ]; do
            if sshpass -e ssh "''${ssh_args[@]}" \
                 -o ConnectTimeout=2 \
                 -o PreferredAuthentications=password \
                 -o PubkeyAuthentication=no \
                 test@localhost true 2>/dev/null; then
              exit 0
            fi
            sleep 1
          done
          echo "agent-vm: ssh did not come up within ''${timeout}s" >&2
          exit 1
          ;;

        key|type|screenshot|move|click)
          export AGENT_VM_QMP="$qmp"
          exec python3 ${./qmp.py} "$cmd" "$@"
          ;;

        log)
          exec tail "$@" "$serial"
          ;;

        help|--help|-h|*)
          cat <<EOF
      Usage: agent-vm <command> [args...]

        run                start the headless test-machine VM
        wait [seconds]     block until SSH answers (default 120s)
        ssh [args...]      ssh into the guest (test@localhost:2223)
        key <chord>        send a synthetic key chord via QMP
                           (alt-a, ctrl-alt-t, shift-space, …)
        type <text>        type a literal string via QMP
        screenshot <path>  save a PNG framebuffer dump via QMP
        move <x> <y>       warp the absolute pointer to pixel (x, y)
        click <x> <y> [b]  click button b (left/right/middle) at (x, y)
        log [tail args]    print/follow the guest serial console

      State lives at $state_dir.
      EOF
          ;;
      esac
    '';
  }
