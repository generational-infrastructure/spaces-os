# Shared test-machine VM driver (not a flake output; imported directly).
#
# One module owns every idiom the VM wrappers used to copy-paste:
#   - repo-root state-dir discovery (state under <repo>/<stateDirName>)
#   - the sshpass/ssh option set and the ssh-wait polling loop
#   - QMP verb dispatch (key/type/screenshot/move/click) via ./qmp.py
#   - stale-swtpm reaping (./reap-swtpm.sh) before EVERY QEMU launch
#   - the x86_64-only stub for non-x86 build hosts
#   - the AGENT_VM_* env-var names — the string contract with
#     modules/nixos/vm-debug.nix's headless QEMU options (that module
#     imports this file for the names)
#
# Consumers: packages/agent-vm (one headless node), packages/remote-agent-vm
# (two headless nodes + GUI twins), packages/test-vm (single GUI launcher,
# mkVmLauncher), modules/nixos/vm-debug.nix (env names only).
let
  # Env-var names the driver exports for the qemu-vm runner and
  # vm-debug.nix's headless QEMU options read back. Single owner of the
  # string contract; qmp.py's fallback default also assumes `qmp`.
  env = {
    qmp = "AGENT_VM_QMP"; # unix socket QEMU serves QMP on
    serial = "AGENT_VM_SERIAL"; # file QEMU appends the serial console to
    vnc = "AGENT_VM_VNC"; # VNC listen address (host:display)
  };

  # Explanatory stub for non-x86 build hosts. Callers keep their VM
  # derivations unforced on this branch, so evaluating it never touches
  # the x86-pinned test-machine config — `nix flake check` succeeds on
  # aarch64 without cross-building the x86 VM.
  mkStub =
    pkgs: name: stubName:
    pkgs.runCommand "${stubName}-x86_64-only" { } ''
      mkdir -p "$out/bin"
      cat > "$out/bin/${name}" <<'EOF'
      #!/bin/sh
      echo "${stubName} is x86_64-linux only; no aarch64 test-machine host yet." >&2
      exit 1
      EOF
      chmod +x "$out/bin/${name}"
    '';

  stateDirDiscovery = stateDirName: ''
    # Locate the repo root so state is the same regardless of cwd.
    state_dir=$PWD/${stateDirName}
    d=$PWD
    while [ "$d" != / ]; do
      if [ -d "$d/.jj" ] || [ -d "$d/.git" ]; then
        state_dir="$d/${stateDirName}"
        break
      fi
      d=$(dirname "$d")
    done

    # Unix sockets (QMP, swtpm control) must live OUTSIDE the repo: a
    # socket anywhere in the worktree breaks every `nix build` on the
    # flake ("has an unsupported type" during the path: fetch). Key the
    # dir to the state-dir path so concurrent checkouts don't collide.
    sock_base="${stateDirName}"
    sock_dir="/tmp/''${sock_base#.}-$(printf %s "$state_dir" | sha256sum | cut -c1-12)"
    mkdir -p -- "$sock_dir"
  '';

  reap = builtins.readFile ./reap-swtpm.sh;
in
{
  inherit env;

  # Build a VM wrapper CLI.
  #
  #   mkVmDriver {
  #     pkgs;
  #     name;                # CLI + binary name
  #     nodes = {            # one attr per VM
  #       <node> = {
  #         vm;              # system.build.vm derivation (headless)
  #         sshPort;         # host port forwarded to guest :22
  #         guiVm ? null;    # GUI twin; a `gui` verb appears when every
  #                          # node has a non-null one
  #         vnc ? null;      # value for $AGENT_VM_VNC (multi-node headless run)
  #         disk ? "<node>.qcow2";
  #         description ? <node>;   # help-text footer (multi-node)
  #       };
  #     };
  #     stateDirName ? ".<name>";   # under the repo root
  #     waitTimeout ? 120;          # default `wait` seconds
  #     runBanner ? ""; guiBanner ? "";  # extra echo lines after backgrounding
  #     stubName ? name;            # non-x86 stub message/drv name
  #   }
  #
  # With one node the verbs take no selector (agent-vm); with several,
  # every verb takes a leading <node> argument (remote-agent-vm).
  mkVmDriver =
    {
      pkgs,
      name,
      nodes,
      # Selector/help ordering (attrNames sorts alphabetically otherwise).
      nodeOrder ? null,
      stateDirName ? ".${name}",
      waitTimeout ? 120,
      runBanner ? "",
      guiBanner ? "",
      stubName ? name,
    }:
    if pkgs.stdenv.hostPlatform.system != "x86_64-linux" then
      mkStub pkgs name stubName
    else
      let
        inherit (pkgs) lib;
        names = if nodeOrder != null then nodeOrder else lib.attrNames nodes;
        multi = builtins.length names > 1;
        # "both VMs" when there are exactly two, "all VMs" beyond that.
        allWord = if builtins.length names == 2 then "both" else "all";
        only = builtins.head names;
        node = n: nodes.${n};
        # node names may contain '-'; shell variable fragments may not.
        san = n: lib.replaceStrings [ "-" ] [ "_" ] n;
        diskOf = n: (node n).disk or "${n}.qcow2";
        port = n: toString (node n).sshPort;
        hasGui = lib.all (n: (node n).guiVm or null != null) names;
        each = f: lib.concatMapStrings f names;
        eachSep = sep: f: lib.concatMapStringsSep sep f names;
        nodeAlt = lib.concatStringsSep "|" names;

        # ------------------------------------------------------------------
        # the verb dispatcher
        # ------------------------------------------------------------------
        nodeTables = ''
          # Per-node lookups; unknown node → message + rc 2 (the $(…)
          # callers run under set -e, so the verb aborts with that status).
          node_port() {
            case "$1" in
          ${eachSep "\n" (n: "    ${n}) echo ${port n} ;;")}
              *) echo "${name}: unknown node '$1' (use ${nodeAlt})" >&2; return 2 ;;
            esac
          }
          node_sock() {
            case "$1" in
          ${eachSep "\n" (n: "    ${n}) echo \"$sock_dir/${n}-qmp.sock\" ;;")}
              *) echo "${name}: unknown node '$1' (use ${nodeAlt})" >&2; return 2 ;;
            esac
          }
          node_serial() {
            case "$1" in
          ${eachSep "\n" (n: "    ${n}) echo \"$state_dir/${n}.serial\" ;;")}
              *) echo "${name}: unknown node '$1' (use ${nodeAlt})" >&2; return 2 ;;
            esac
          }
        '';

        # Background one headless node with its env wired up.
        launchOne =
          n:
          let
            v = node n;
            envs = [
              "${env.qmp}=\"$sock_dir/${n}-qmp.sock\""
              "${env.serial}=\"$state_dir/${n}.serial\""
            ]
            ++ lib.optional (v ? vnc && v.vnc != null) "${env.vnc}=${v.vnc}"
            ++ [
              "NIX_DISK_IMAGE=\"$state_dir/${diskOf n}\""
              # ABSOLUTE and outside the repo: swtpm serves unix sockets in
              # this dir, and any socket inside the worktree breaks flake
              # path: fetches ("has an unsupported type").
              "NIX_SWTPM_DIR=\"$sock_dir/${n}-swtpm\""
              "QEMU_KERNEL_PARAMS=\"\${QEMU_KERNEL_PARAMS:-} loglevel=7\""
            ];
          in
          ''
            run_${san n}=(${v.vm}/bin/run-*-vm)
            ${lib.concatStringsSep " \\\n" envs} \
              "''${run_${san n}[0]}" &
            pid_${san n}=$!

          '';

        pidList = eachSep " " (n: "$pid_${san n}");
        pidEcho = eachSep ", " (n: "${n} pid $pid_${san n}");

        runVerb =
          if multi then
            ''
              run)
                mkdir -p -- "$state_dir"
                rm -f -- ${eachSep " " (n: "\"$sock_dir/${n}-qmp.sock\"")}
              ${eachSep "\n" (n: "  : >\"$state_dir/${n}.serial\"")}
                echo "${name}: state at $state_dir (sockets: $sock_dir)"
                cd "$state_dir"

                # The qemu-vm runner's swtpm daemon can outlive a hard-killed
                # QEMU (the trap below, a killed supervisor, dropped terminal),
                # wedging every later launch on the TPM state lock — reap orphans
                # before launching; abort if one still serves a live VM. Distinct
                # per-node state dirs keep the swtpms off each other's lockfile.
              ${eachSep "\n" (n: "  reap_swtpm \"$sock_dir/${n}-swtpm\"")}

                # loglevel=7 so kernel boot info reaches the serial logs; the
                # test-machine baseline has loglevel=4 (warnings only).
              ${each launchOne}
                # shellcheck disable=SC2064
                trap "kill ${pidList} 2>/dev/null || true" EXIT INT TERM
                echo "${name}: ${pidEcho}"
              ${runBanner}
                wait
                ;;
            ''
          else
            ''
              run)
                mkdir -p -- "$state_dir"
                rm -f -- "$qmp"
                : >"$serial"
                echo "${name}: state at $state_dir (serial: $serial, sockets: $sock_dir)"
                cd "$state_dir"
                # swtpm serves unix sockets in NIX_SWTPM_DIR, so it must live
                # outside the repo (any worktree socket breaks flake path:
                # fetches), and its daemon can outlive a hard-killed QEMU
                # (a killed supervisor, dropped terminal), wedging every later
                # launch on the TPM state lock. Reap any orphan first; abort
                # if that swtpm still serves a live VM.
                export NIX_SWTPM_DIR="''${NIX_SWTPM_DIR:-$sock_dir/test-machine-swtpm}"
                reap_swtpm "$NIX_SWTPM_DIR"
                export ${env.qmp}="$qmp"
                export ${env.serial}="$serial"
                export NIX_DISK_IMAGE="$state_dir/${diskOf only}"
                # loglevel=7 so kernel boot info reaches the serial log; the
                # test-machine baseline has loglevel=4 (warnings only).
                export QEMU_KERNEL_PARAMS="''${QEMU_KERNEL_PARAMS:-} loglevel=7"
                run_vm=(${(node only).vm}/bin/run-*-vm)
                exec "''${run_vm[0]}"
                ;;
            '';

        guiLaunchOne = n: ''
          gui_run_${san n}=(${(node n).guiVm}/bin/run-*-vm)
          NIX_DISK_IMAGE="$state_dir/gui-${diskOf n}" NIX_SWTPM_DIR="$sock_dir/gui-${n}-swtpm" "''${gui_run_${san n}[0]}" &
          pid_gui_${san n}=$!

        '';

        guiPidList = eachSep " " (n: "$pid_gui_${san n}");
        guiPidEcho = eachSep ", " (n: "${n} pid $pid_gui_${san n}");

        guiVerb = ''
          gui)
            mkdir -p -- "$state_dir"
            cd "$state_dir"
            # Same swtpm hygiene as `run`; each GUI twin gets its own
            # per-node swtpm dir under $sock_dir.
          ${eachSep "\n" (n: "  reap_swtpm \"$sock_dir/gui-${n}-swtpm\"")}

          ${each guiLaunchOne}
            # shellcheck disable=SC2064
            trap "kill ${guiPidList} 2>/dev/null || true" EXIT INT TERM
            echo "${name}: native QEMU windows (${guiPidEcho})"
          ${guiBanner}
            wait
            ;;
        '';

        waitVerb =
          if multi then
            ''
              wait)
                timeout="''${1:-${toString waitTimeout}}"
                deadline=$(( $(date +%s) + timeout ))
              ${eachSep "\n" (n: "  ok_${san n}=0")}
                while [ "$(date +%s)" -lt "$deadline" ]; do
              ${each (n: ''
                if [ "$ok_${san n}" -eq 0 ] && ssh_alive ${port n}; then
                  ok_${san n}=1
                  echo "${name}: ${n} ssh up"
                fi
              '')}
                  if ${eachSep " && " (n: "[ \"$ok_${san n}\" -eq 1 ]")}; then
                    exit 0
                  fi
                  sleep 1
                done
                echo "${name}: VMs did not ${allWord} answer ssh within ''${timeout}s (${
                  eachSep " " (n: "${n}=$ok_${san n}")
                })" >&2
                exit 1
                ;;
            ''
          else
            ''
              wait)
                timeout="''${1:-${toString waitTimeout}}"
                deadline=$(( $(date +%s) + timeout ))
                while [ "$(date +%s)" -lt "$deadline" ]; do
                  if ssh_alive ${port only}; then
                    exit 0
                  fi
                  sleep 1
                done
                echo "${name}: ssh did not come up within ''${timeout}s" >&2
                exit 1
                ;;
            '';

        sshVerb =
          if multi then
            ''
              ssh)
                sel="''${1:-}"
                if [ "$#" -gt 0 ]; then shift; fi
                sshport=$(node_port "$sel")
                ssh_settle "$sshport"
                export SSHPASS=test
                exec sshpass -e ssh "''${ssh_common[@]}" -p "$sshport" test@localhost "$@"
                ;;
            ''
          else
            ''
              ssh)
                ssh_settle ${port only}
                export SSHPASS=test
                exec sshpass -e ssh "''${ssh_common[@]}" -p ${port only} test@localhost "$@"
                ;;
            '';

        qmpVerb =
          if multi then
            ''
              key|type|screenshot|move|click)
                sel="''${1:-}"
                if [ "$#" -gt 0 ]; then shift; fi
                sock=$(node_sock "$sel")
                ${env.qmp}="$sock" exec python3 ${./qmp.py} "$cmd" "$@"
                ;;
            ''
          else
            ''
              key|type|screenshot|move|click)
                export ${env.qmp}="$qmp"
                exec python3 ${./qmp.py} "$cmd" "$@"
                ;;
            '';

        logVerb =
          if multi then
            ''
              log)
                sel="''${1:-}"
                if [ "$#" -gt 0 ]; then shift; fi
                serial=$(node_serial "$sel")
                exec tail "$@" "$serial"
                ;;
            ''
          else
            ''
              log)
                exec tail "$@" "$serial"
                ;;
            '';

        helpText =
          if multi then
            lib.concatStrings [
              ''
                Usage: ${name} <command> [args...]

                  run                       start ${allWord} VMs headless (QMP + VNC; for scripting)
              ''
              # plain string: a one-line '' block would strip the 2-space indent
              (lib.optionalString hasGui "  gui                       start ${allWord} VMs in native QEMU windows (click around)\n")
              ''
                  wait [seconds]            block until ${allWord} answer SSH (default ${toString waitTimeout}s)
                  ssh <node> [args...]      ssh into a guest (${eachSep ", " (n: "${n}=:${port n}")})
                  key <node> <chord>        send a synthetic key chord via QMP
                  type <node> <text>        type a literal string into the focused field
                  screenshot <node> <path>  save a PNG framebuffer dump via QMP
                  move <node> <x> <y>       warp the absolute pointer to pixel (x, y)
                  click <node> <x> <y> [b]  click button b (left/right/middle) at (x, y)
                  log <node> [tail args]    print/follow a guest serial console

                  <node> is ${eachSep " or " (n: "'${n}' (${(node n).description or n})")}.
                State lives at $state_dir.
              ''
            ]
          else
            lib.concatStrings [
              ''
                Usage: ${name} <command> [args...]

                  run                start the headless test-machine VM
              ''
              # plain string: a one-line '' block would strip the 2-space indent
              (lib.optionalString hasGui "  gui                start the VM in a native QEMU window (click around)\n")
              ''
                  wait [seconds]     block until SSH answers (default ${toString waitTimeout}s)
                  ssh [args...]      ssh into the guest (test@localhost:${port only})
                  key <chord>        send a synthetic key chord via QMP
                                     (alt-a, ctrl-alt-t, shift-space, …)
                  type <text>        type a literal string via QMP
                  screenshot <path>  save a PNG framebuffer dump via QMP
                  move <x> <y>       warp the absolute pointer to pixel (x, y)
                  click <x> <y> [b]  click button b (left/right/middle) at (x, y)
                  log [tail args]    print/follow the guest serial console

                State lives at $state_dir.
              ''
            ];

        helpVerb = "help|--help|-h|*)\n  cat <<EOF\n" + helpText + "EOF\n  ;;\n";

        cliScript = lib.concatStrings [
          (stateDirDiscovery stateDirName)
          (lib.optionalString (!multi) ''
            qmp="$sock_dir/qmp.sock"
            serial="$state_dir/serial.log"
          '')
          "\n"
          reap
          ''

            ssh_common=(
              -o StrictHostKeyChecking=no
              -o UserKnownHostsFile=/dev/null
              -o LogLevel=ERROR
            )

            # One sshd liveness probe (used by `wait`); the ssh polling
            # idiom lives only here.
            ssh_alive() {
              SSHPASS="test" sshpass -e ssh "''${ssh_common[@]}" -p "$1" \
                -o ConnectTimeout=2 \
                -o PreferredAuthentications=password \
                -o PubkeyAuthentication=no \
                test@localhost true 2>/dev/null
            }

            # Quiet readiness gate for the `ssh` verb. An `ssh` issued before
            # the guest sshd answers the forwarded port prints "connect ...:
            # Connection refused" on stderr — noise in an agent's terminal.
            # Poll ssh_alive quietly for a short window first; then fall
            # through to exec the real ssh either way, so a genuinely-down VM
            # still surfaces one clean error instead of a burst. Bounded by
            # AGENT_VM_SSH_SETTLE seconds (0 disables the gate).
            ssh_settle() {
              deadline=$(( $(date +%s) + "''${AGENT_VM_SSH_SETTLE:-60}" ))
              while [ "$(date +%s)" -lt "$deadline" ]; do
                ssh_alive "$1" && return 0
                sleep 1
              done
            }

          ''
          (lib.optionalString multi nodeTables)
          ''

            cmd="''${1:-help}"
            if [ "$#" -gt 0 ]; then shift; fi

            case "$cmd" in
          ''
          runVerb
          (lib.optionalString hasGui guiVerb)
          waitVerb
          sshVerb
          qmpVerb
          logVerb
          helpVerb
          "esac\n"
        ];
      in
      pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = [
          pkgs.openssh
          pkgs.sshpass
          pkgs.python3
          pkgs.coreutils
          # pgrep, for the stale-swtpm reaper.
          pkgs.procps
        ];
        text = cliScript;
      };

  # Build an exec-style VM launcher (test-vm): no verbs, argv passes
  # straight through to the single VM's qemu-vm runner.
  #
  #   mkVmLauncher {
  #     pkgs;
  #     name;                # CLI + binary name
  #     vm;                  # system.build.vm derivation
  #     disk;                # qcow2 filename under the state dir
  #     stateDirName ? ".<name>";   # under the repo root
  #     preRun ? "";         # shell run before the VM
  #     stubName ? name;     # non-x86 stub message/drv name
  #   }
  mkVmLauncher =
    {
      pkgs,
      name,
      vm,
      disk,
      stateDirName ? ".${name}",
      preRun ? "",
      stubName ? name,
    }:
    if pkgs.stdenv.hostPlatform.system != "x86_64-linux" then
      mkStub pkgs name stubName
    else
      pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = [
          pkgs.coreutils
          # pgrep, for the stale-swtpm reaper.
          pkgs.procps
        ];
        text = pkgs.lib.concatStrings [
          (stateDirDiscovery stateDirName)
          ''
            mkdir -p -- "$state_dir"
            export NIX_DISK_IMAGE="$state_dir/${disk}"

            ${reap}
            # swtpm serves unix sockets in NIX_SWTPM_DIR, so it must live
            # outside the repo (a worktree socket breaks flake path: fetches),
            # and its daemon can outlive a hard-killed QEMU, wedging every
            # later launch on the TPM state lock. Reap any orphan first;
            # abort if that swtpm still serves a live VM.
            export NIX_SWTPM_DIR="''${NIX_SWTPM_DIR:-$sock_dir/${name}-swtpm}"
            reap_swtpm "$NIX_SWTPM_DIR"

          ''
          preRun
          ''
            # No exec: keep the shell alive so any EXIT trap installed by the
            # pre-run hook above runs after QEMU exits.
            run_vm=(${vm}/bin/run-*-vm)
            "''${run_vm[0]}" "$@"
          ''
        ];
      };
}
