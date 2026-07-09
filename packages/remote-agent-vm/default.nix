# Two-VM interactive harness for the remote-pi topology: the 2-node
# instantiation of the shared VM driver (../agent-vm/lib.nix), booting BOTH
# halves so you can drive the desktop chat panel against a real REMOTE
# pi-sessiond executor, the same way agent-vm drives a single desktop:
#
#   server  — the per-user `--user` pi-sessiond executor + a deterministic mock LLM,
#             192.0.2.1, ssh on host :2223. No desktop.
#   client  — the full test-machine desktop (greetd -> niri -> pi-chat),
#             192.0.2.2, ssh on host :2224, with services.pi-chat.wsUrl
#             pointed at ws://192.0.2.1:8770.
#
# The two VMs share an L2 segment via QEMU socket multicast (eth1), so the
# client reaches the server with no host involvement. Every verb takes a
# <server|client> selector; otherwise the ergonomics mirror agent-vm:
#
#   nix run .#remote-agent-vm -- run                  # background; long-running
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
let
  inherit (pkgs) lib;
  vmDriver = import ../agent-vm/lib.nix;
  token = "remote-agent-vm-secret";
  wsPort = 8770;
  llmPort = 8013;
  # Owned by checks/pi-remote-session (its deterministic mock LLM server);
  # bound explicitly here rather than reached via a hidden relative path
  # inside the module below.
  mockLlm = ../../checks/pi-remote-session/mock-llm.py;

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
        # The per-user `--user` executor runs under the (linger-enabled) test
        # user's manager — no root daemon. docs/pi-sessiond-per-user-refactor.md.
        users.users.test.linger = true;
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
in
vmDriver.mkVmDriver {
  inherit pkgs;
  name = "remote-agent-vm";
  waitTimeout = 180;
  # Selector help/errors say "server|client" (topology order), not
  # the alphabetical attrNames order.
  nodeOrder = [
    "server"
    "client"
  ];
  nodes = {
    # Headless (QMP socket + VNC) for scripting and the AGENTS.md agent
    # loop; guiVm = native GTK windows (vm-debug's default display) for
    # driving by hand. All lazy under the non-x86 stub.
    server = {
      vm = mkVm (serverModules ++ [ headless ]);
      guiVm = mkVm serverModules;
      sshPort = 2223;
      vnc = "127.0.0.1:99";
      description = "pi-sessiond executor";
    };
    client = {
      vm = mkVm (clientModules ++ [ headless ]);
      guiVm = mkVm clientModules;
      sshPort = 2224;
      vnc = "127.0.0.1:100";
      description = "desktop panel";
    };
  };
  runBanner = ''
    echo "remote-agent-vm:   server  ssh -p 2223 test@localhost    VNC 127.0.0.1:5999"
    echo "remote-agent-vm:   client  ssh -p 2224 test@localhost    VNC 127.0.0.1:6000  <- the desktop panel"
    echo "remote-agent-vm: point a VNC viewer at 127.0.0.1:6000 to click around the client (password: none)."
  '';
  guiBanner = ''
    echo "remote-agent-vm: in the CLIENT window, press Alt+A to open the chat panel, then click + type."
    echo "remote-agent-vm: ssh also works — server :2223, client :2224 (user/pass test/test). Ctrl-C stops both."
  '';
}
