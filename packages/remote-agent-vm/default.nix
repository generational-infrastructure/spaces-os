# Two-VM interactive harness for the remote-pi topology, modeled on
# packages/agent-vm/default.nix but booting BOTH halves so you can drive the
# desktop chat panel against a real REMOTE pi-sessiond executor, the same way
# agent-vm drives a single desktop:
#
#   server  — services.pi-sessiond executor + a deterministic mock LLM,
#             192.0.2.1, ssh on host :2223. No desktop.
#   client  — the full test-machine desktop (greetd -> niri -> pi-chat),
#             192.0.2.2, ssh on host :2224, with services.pi-chat.wsUrl
#             pointed at ws://192.0.2.1:8770.
#
# The two VMs share an L2 segment via QEMU socket multicast (eth1), so the
# client reaches the server with no host involvement. Every verb takes a
# <server|client> selector; otherwise the ergonomics mirror agent-vm:
#
#   pueue add -- nix run .#remote-agent-vm -- run     # background; long-running
#   nix run .#remote-agent-vm -- wait                 # both ssh answer
#   nix run .#remote-agent-vm -- ssh client systemctl --user is-active niri
#   nix run .#remote-agent-vm -- key client alt-a     # open the chat panel
#   nix run .#remote-agent-vm -- click client 640 700
#   nix run .#remote-agent-vm -- screenshot client .remote-agent-vm/panel.png
#   nix run .#remote-agent-vm -- log server -f
#
# All state lands in <repo>/.remote-agent-vm/ (qcow2s, QMP sockets, serial
# logs). x86_64-linux only — test-machine is x86-pinned.
{
  inputs,
  pkgs,
  ...
}:
if pkgs.stdenv.hostPlatform.system != "x86_64-linux" then
  pkgs.runCommand "remote-agent-vm-x86_64-only" { } ''
    mkdir -p "$out/bin"
    cat > "$out/bin/remote-agent-vm" <<'EOF'
    #!/bin/sh
    echo "remote-agent-vm is x86_64-linux only; no aarch64 test-machine host yet." >&2
    exit 1
    EOF
    chmod +x "$out/bin/remote-agent-vm"
  ''
else
  let
    inherit (pkgs) lib;
    token = "remote-agent-vm-secret";
    wsPort = 8770;
    llmPort = 8013;
    mockLlm = ../../checks/pi-remote-session/mock-llm.py;
    qmp = ../agent-vm/qmp.py;

    # Per-node VM-only wiring: distinct host SSH port + RAM, plus a second NIC
    # (eth1) wired to a shared QEMU socket-multicast L2 segment with a static
    # IP. eth0 stays the qemu-vm user NIC (slirp DHCP + the ssh hostfwd).
    netNode =
      {
        ip,
        mac,
        sshPort,
        mem,
      }:
      {
        virtualisation.vmVariant = {
          virtualisation.memorySize = lib.mkForce mem;
          virtualisation.forwardPorts = lib.mkForce [
            {
              from = "host";
              host.port = sshPort;
              guest.port = 22;
            }
          ];
          virtualisation.qemu.options = [
            "-netdev socket,id=l2,mcast=230.0.0.1:1234"
            "-device virtio-net-pci,netdev=l2,mac=${mac}"
          ];
          boot.kernelParams = [ "net.ifnames=0" ];
          networking.interfaces.eth1 = {
            useDHCP = lib.mkForce false;
            ipv4.addresses = [
              {
                address = ip;
                prefixLength = 24;
              }
            ];
          };
        };
      };

    headless = {
      services.spaces.vm-debug.headless = true;
    };

    # Server: pi-sessiond executor + mock LLM, no desktop.
    serverModules = [
      inputs.self.nixosModules.test-support
      inputs.self.nixosModules.pi-sessiond
      (netNode {
        ip = "192.0.2.1";
        mac = "52:54:00:ab:cd:01";
        sshPort = 2223;
        mem = 2048;
      })
      (
        { pkgs, lib, ... }:
        {
          services.greetd.enable = lib.mkForce false;
          services.llama-swap.enable = lib.mkForce false;
          services.pi-sessiond = {
            enable = true;
            executorId = "server";
            host = "0.0.0.0";
            port = wsPort;
            inherit token;
            llmUrl = "http://127.0.0.1:${toString llmPort}";
            defaultModel = "mock-model";
            defaultProvider = "local";
            openFirewall = true;
          };
          systemd.services.pi-remote-mock-llm = {
            description = "OpenAI-compatible mock LLM for remote-agent-vm";
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = "${pkgs.python3}/bin/python3 ${mockLlm} ${toString llmPort}";
              Restart = "on-failure";
            };
          };
        }
      )
    ];

    # Client: the full desktop; panel pinned at the remote executor.
    clientModules = [
      inputs.self.nixosModules.test-support
      (netNode {
        ip = "192.0.2.2";
        mac = "52:54:00:ab:cd:02";
        sshPort = 2224;
        mem = 4096;
      })
      (
        { lib, ... }:
        {
          services.pi-chat = {
            skills = lib.mkForce { };
            extensions.bash-confirm = false;
            wsUrl = "ws://192.0.2.1:${toString wsPort}";
            wsToken = token;
            # The loopback executor is on by default; pin new sessions at
            # the remote half so the topology actually exercises it.
            defaultExecutor = "remote";
          };
          services.llama-swap.enable = lib.mkForce false;
        }
      )
    ];

    mkVm =
      modules:
      (inputs.self.nixosConfigurations.test-machine.extendModules {
        inherit modules;
      }).config.system.build.vm;

    # Headless (QMP socket + VNC) for scripting and the AGENTS.md agent loop.
    serverVm = mkVm (serverModules ++ [ headless ]);
    clientVm = mkVm (clientModules ++ [ headless ]);
    # Native GTK windows (vm-debug's default display) for driving by hand.
    guiServerVm = mkVm serverModules;
    guiClientVm = mkVm clientModules;
  in
  pkgs.writeShellApplication {
    name = "remote-agent-vm";
    runtimeInputs = [
      pkgs.sshpass
      pkgs.openssh
      pkgs.python3
      pkgs.coreutils
    ];
    text = ''
      # Locate the repo root so state is the same regardless of cwd.
      state_dir=$PWD/.remote-agent-vm
      d=$PWD
      while [ "$d" != / ]; do
        if [ -d "$d/.jj" ] || [ -d "$d/.git" ]; then
          state_dir="$d/.remote-agent-vm"
          break
        fi
        d=$(dirname "$d")
      done

      ssh_common=(
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
      )

      node_port() {
        case "$1" in
          server) echo 2223 ;;
          client) echo 2224 ;;
          *) echo "remote-agent-vm: unknown node '$1' (use server|client)" >&2; return 2 ;;
        esac
      }
      node_sock() {
        case "$1" in
          server) echo "$state_dir/server-qmp.sock" ;;
          client) echo "$state_dir/client-qmp.sock" ;;
          *) echo "remote-agent-vm: unknown node '$1' (use server|client)" >&2; return 2 ;;
        esac
      }

      cmd="''${1:-help}"
      if [ "$#" -gt 0 ]; then shift; fi

      case "$cmd" in
        run)
          mkdir -p -- "$state_dir"
          rm -f -- "$state_dir/server-qmp.sock" "$state_dir/client-qmp.sock"
          : >"$state_dir/server.serial"
          : >"$state_dir/client.serial"
          echo "remote-agent-vm: state at $state_dir"
          cd "$state_dir"

          server_run=(${serverVm}/bin/run-*-vm)
          client_run=(${clientVm}/bin/run-*-vm)

          AGENT_VM_QMP="$state_dir/server-qmp.sock" \
          AGENT_VM_SERIAL="$state_dir/server.serial" \
          AGENT_VM_VNC=127.0.0.1:99 \
          NIX_DISK_IMAGE="$state_dir/server.qcow2" \
          QEMU_KERNEL_PARAMS="loglevel=7" \
            "''${server_run[0]}" &
          spid=$!

          AGENT_VM_QMP="$state_dir/client-qmp.sock" \
          AGENT_VM_SERIAL="$state_dir/client.serial" \
          AGENT_VM_VNC=127.0.0.1:100 \
          NIX_DISK_IMAGE="$state_dir/client.qcow2" \
          QEMU_KERNEL_PARAMS="loglevel=7" \
            "''${client_run[0]}" &
          cpid=$!

          # shellcheck disable=SC2064
          trap "kill $spid $cpid 2>/dev/null || true" EXIT INT TERM
          echo "remote-agent-vm: server pid $spid, client pid $cpid"
          echo "remote-agent-vm:   server  ssh -p 2223 test@localhost    VNC 127.0.0.1:5999"
          echo "remote-agent-vm:   client  ssh -p 2224 test@localhost    VNC 127.0.0.1:6000  <- the desktop panel"
          echo "remote-agent-vm: point a VNC viewer at 127.0.0.1:6000 to click around the client (password: none)."
          wait
          ;;

        gui)
          mkdir -p -- "$state_dir"
          cd "$state_dir"
          gui_server_run=(${guiServerVm}/bin/run-*-vm)
          gui_client_run=(${guiClientVm}/bin/run-*-vm)

          NIX_DISK_IMAGE="$state_dir/gui-server.qcow2" "''${gui_server_run[0]}" &
          spid=$!
          NIX_DISK_IMAGE="$state_dir/gui-client.qcow2" "''${gui_client_run[0]}" &
          cpid=$!

          # shellcheck disable=SC2064
          trap "kill $spid $cpid 2>/dev/null || true" EXIT INT TERM
          echo "remote-agent-vm: two native QEMU windows (server pid $spid, client pid $cpid)"
          echo "remote-agent-vm: in the CLIENT window, press Alt+A to open the chat panel, then click + type."
          echo "remote-agent-vm: ssh also works — server :2223, client :2224 (user/pass test/test). Ctrl-C stops both."
          wait
          ;;

        wait)
          timeout="''${1:-180}"
          deadline=$(( $(date +%s) + timeout ))
          export SSHPASS=test
          ok_s=0
          ok_c=0
          while [ "$(date +%s)" -lt "$deadline" ]; do
            if [ "$ok_s" -eq 0 ] && sshpass -e ssh "''${ssh_common[@]}" \
                 -p 2223 -o ConnectTimeout=2 \
                 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                 test@localhost true 2>/dev/null; then
              ok_s=1
              echo "remote-agent-vm: server ssh up"
            fi
            if [ "$ok_c" -eq 0 ] && sshpass -e ssh "''${ssh_common[@]}" \
                 -p 2224 -o ConnectTimeout=2 \
                 -o PreferredAuthentications=password -o PubkeyAuthentication=no \
                 test@localhost true 2>/dev/null; then
              ok_c=1
              echo "remote-agent-vm: client ssh up"
            fi
            if [ "$ok_s" -eq 1 ] && [ "$ok_c" -eq 1 ]; then
              exit 0
            fi
            sleep 1
          done
          echo "remote-agent-vm: VMs did not both answer ssh within ''${timeout}s (server=$ok_s client=$ok_c)" >&2
          exit 1
          ;;

        ssh)
          node="''${1:-}"
          if [ "$#" -gt 0 ]; then shift; fi
          port=$(node_port "$node")
          export SSHPASS=test
          exec sshpass -e ssh "''${ssh_common[@]}" -p "$port" test@localhost "$@"
          ;;

        key | type | screenshot | move | click)
          node="''${1:-}"
          if [ "$#" -gt 0 ]; then shift; fi
          sock=$(node_sock "$node")
          AGENT_VM_QMP="$sock" exec python3 ${qmp} "$cmd" "$@"
          ;;

        log)
          node="''${1:-}"
          if [ "$#" -gt 0 ]; then shift; fi
          case "$node" in
            server) exec tail "$@" "$state_dir/server.serial" ;;
            client) exec tail "$@" "$state_dir/client.serial" ;;
            *) echo "remote-agent-vm: unknown node '$node' (use server|client)" >&2; exit 2 ;;
          esac
          ;;

        help | --help | -h | *)
          cat <<EOF
      Usage: remote-agent-vm <command> [args...]

        run                       start both VMs headless (QMP + VNC; for scripting)
        gui                       start both VMs in native QEMU windows (click around)
        wait [seconds]            block until both answer SSH (default 180s)
        ssh <node> [args...]      ssh into a guest (server=:2223, client=:2224)
        key <node> <chord>        send a synthetic key chord via QMP
        type <node> <text>        type a literal string into the focused field
        screenshot <node> <path>  save a PNG framebuffer dump via QMP
        move <node> <x> <y>       warp the absolute pointer to pixel (x, y)
        click <node> <x> <y> [b]  click button b (left/right/middle) at (x, y)
        log <node> [tail args]    print/follow a guest serial console

        <node> is 'server' (pi-sessiond executor) or 'client' (desktop panel).
      State lives at $state_dir.
      EOF
          ;;
      esac
    '';
  }
