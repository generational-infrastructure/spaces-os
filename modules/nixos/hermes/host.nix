# Host-side wiring per user: provisioning drop-ins on the microvm@ and
# virtiofsd units (ssh keys, state-vault, credentials), the root-held
# dashboard-forward and spaces-bridge socket units, the timezone mirror,
# tmpfiles and the per-VM netfilter marker groups.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hermes-microvm;
  hlib = import ./lib.nix { inherit lib; };
  inherit (hlib)
    vmName
    vmGroup
    baseDir
    exchangeDir
    guestWorkspace
    dashboardGuestPort
    cidFor
    spacesVsockPort
    ;
  scripts = import ./scripts.nix {
    inherit
      lib
      pkgs
      hlib
      cfg
      ;
  };
  inherit (scripts) provisionScript tzSyncScript desktopTokenScript;

  # Accept-time peer-CID check + splice for the spaces bridge — see
  # ./vsock-spaces-bridge.rs for why the CID check IS the access control.
  spacesBridgeBin = pkgs.writers.writeRustBin "hermes-vsock-spaces-bridge" {
    rustcArgs = [ "-O" "--edition" "2021" ];
  } ./vsock-spaces-bridge.rs;

  # Assembled under static top-level option keys — a config-dependent
  # mkMerge list at the config root makes option-key resolution depend on
  # cfg.enabledUsers (infinite recursion).
  forEachUser = f: lib.mkMerge (lib.mapAttrsToList f cfg.enabledUsers);
in
{
  config = lib.mkIf cfg.enable {
    # vhost-vsock for the ssh/dashboard channels (device node is kvm-group
    # via systemd's default udev rules; the VM units get kvm as a
    # supplementary group).
    boot.kernelModules = [ "vhost_vsock" ];

    # Venus host side: qemu (unit SupplementaryGroups render/video) opens the
    # node and /dev/udmabuf (root-only by default — hand it to the render
    # group). No DeviceAllow needed: no microvm unit sets a DevicePolicy.
    services.udev.extraRules = lib.mkIf cfg.gpu.enable ''
      KERNEL=="udmabuf", GROUP="render", MODE="0660"
    '';

    # Re-mirror the timezone whenever /etc/localtime is swapped.
    systemd.paths.hermes-microvm-timezone = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = "/etc/localtime";
    };

    systemd.services = lib.mkMerge [
      {
        hermes-microvm-timezone = {
          description = "Mirror host timezone into hermes microvm shares";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${tzSyncScript}";
          };
        };
      }
      (forEachUser (
        user: ucfg: {
          "microvm@${vmName user}" = {
            # "+" = run with full privileges (the unit runs as the owner)
            serviceConfig.ExecStartPre = [ "+${provisionScript user ucfg}" ];
            # Override upstream's shared `microvm` user: the VM runs AS ITS
            # OWNER — the agent inside already acts for the owner, so an
            # escape lands in the same trust domain (accepted trade-off; the
            # win: this module never contributes to users.users, which would
            # be the auto-provision fixpoint — see options.nix). Netfilter
            # still tells guest egress from the owner's own traffic by the
            # per-VM marker group below (firewall.nix --suppl-groups match).
            serviceConfig.User = user;
            # kvm: /dev/kvm, vhost-vsock and the virtiofsd sockets (upstream
            # --socket-group=kvm) — granted to the unit, not the account;
            # render/video for Venus; the marker group for the firewall.
            serviceConfig.SupplementaryGroups = [
              "kvm"
              (vmGroup user)
            ]
            ++ lib.optionals cfg.gpu.enable [
              "render"
              "video"
            ];
            # Per-secret systemd credentials: qemu (the unit's main process)
            # reads them from $CREDENTIALS_DIRECTORY; the guest config maps
            # them through microvm.credentialFiles (fw_cfg). Strict: a
            # missing source file fails the VM start (fail-loud after a
            # forgotten `clan vars generate`).
            serviceConfig.LoadCredential =
              lib.mapAttrsToList (name: path: "${name}:${path}") ucfg.secretEnv
              ++ [ "dashboard_token:${baseDir user}/desktop-token" ];
          };

          # Runs as the shared microvm user upstream but writes the `booted`
          # symlink into the owner-owned VM dir — run it as the owner too.
          # Upstream has no per-instance unit here, so ours must merge as a
          # drop-in (a full unit would lack ExecStart and be rejected).
          "microvm-set-booted@${vmName user}" = {
            overrideStrategy = "asDropin";
            serviceConfig.User = user;
            # First start: upstream activation creates the VM dir as
            # microvm:kvm; own it BEFORE the symlink write (this unit runs
            # before microvm@'s provisioning ExecStartPre gets a chance).
            serviceConfig.ExecStartPre = [
              "+${pkgs.writeShellScript "hermes-vmdir-own-${user}" ''
                chown ${user}:kvm /var/lib/microvms/${vmName user}
                chmod 0750 /var/lib/microvms/${vmName user}
              ''}"
            ];
          };

          # Re-assert share sources at every start. (Upstream defines this
          # unit with overrideStrategy=asDropin; these merge.)
          "microvm-virtiofsd@${vmName user}" = {
            serviceConfig.ExecStartPre = [ "${desktopTokenScript user}" ];
          };

          # Per-connection dashboard forward into the guest over vsock (no
          # slirp hostfwd; the root-held socket unit outlives the VM).
          "hermes-dashboard-fwd-${user}@" = {
            description = "dashboard vsock forward for ${vmName user}";
            serviceConfig = {
              DynamicUser = true;
              ExecStart = "${pkgs.socat}/bin/socat STDIO VSOCK-CONNECT:${toString (cidFor user)}:${toString dashboardGuestPort}";
              StandardInput = "socket";
            };
          };

          # spaces gateway bridge: guest -> AF_VSOCK (host CID 2,
          # hash-derived port) -> socket unit -> this instance (as the
          # owner, who alone may open the 0700 user socket). "auto":
          # the helper resolves /run/user/<euid>/… at connect time; if
          # the user manager is not up yet, the one connection fails
          # and the guest MCP client retries.
          "hermes-spaces-bridge-${user}@" = lib.mkIf ucfg.spacesGateway.enable {
            description = "spaces gateway bridge for ${vmName user}";
            serviceConfig = {
              User = user;
              ExecStart = "${spacesBridgeBin}/bin/hermes-vsock-spaces-bridge ${toString (cidFor user)}";
              StandardInput = "socket";
              # StandardInput=socket would make stderr "inherit" the
              # socket, leaking the rejection message to the dialer.
              StandardError = "journal";
            };
          };

        }
      ))
    ];

    # Listeners are bound by root at boot and never released — no squat
    # window while a VM is down. The dashboard forward is loopback TCP
    # (upstream's Electron client is TCP-only; iptables owner-match
    # gates connects); the spaces bridge listens on AF_VSOCK and the
    # per-connection helper enforces the peer CID at accept.
    systemd.sockets = forEachUser (
      user: ucfg: {
        "hermes-dashboard-fwd-${user}" = {
          description = "dashboard forward socket for ${vmName user}";
          wantedBy = [ "sockets.target" ];
          listenStreams = [ "127.0.0.1:${toString ucfg.dashboardPort}" ];
          socketConfig.Accept = true;
        };
        "hermes-spaces-bridge-${user}" = lib.mkIf ucfg.spacesGateway.enable {
          description = "spaces bridge socket for ${vmName user}";
          wantedBy = [ "sockets.target" ];
          # "vsock::<port>" = bind VMADDR_CID_ANY on the host.
          listenStreams = [ "vsock::${toString (spacesVsockPort user)}" ];
          socketConfig.Accept = true;
          # Any guest can complete a vsock connect (rejection happens
          # post-accept in the helper), so a hostile sibling VM could
          # trip the Accept=yes trigger limit (200/2s) and fail the
          # socket: cross-VM DoS. Rejected instances exit within
          # milliseconds; buildup stays bounded by MaxConnections.
          socketConfig.TriggerLimitIntervalSec = 0;
        };
      }
    );

    # Sole source of truth for state dirs; wipe-and-restart flow is
    # `systemctl restart systemd-tmpfiles-setup` before restarting the VM.
    systemd.tmpfiles.rules = [
      "d /var/lib/hermes-microvm 0755 root root - -"
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (
        user: ucfg:
        [
          "d ${baseDir user} 0755 root root - -"
          "d ${baseDir user}/ssh 0755 root root - -"
          "d ${baseDir user}/guest 0755 root root - -"
          "d ${baseDir user}/guest/ssh 0755 root root - -"
          "d ${baseDir user}/state-vault 0700 root root - -"
          "d ${baseDir user}/state-vault/state 0700 ${user} users - -"
          "d ${exchangeDir user} 0755 ${user} users - -"
          "d ${guestWorkspace user} 0755 ${user} users - -"
        ]
        # The per-user gateway socket must exist at boot, before any
        # interactive login: linger the owner. The file IS the linger
        # protocol (what `loginctl enable-linger` creates; logind reads
        # the dir at startup). Deliberately NOT users.users.<u>.linger —
        # this module must never define users.users (see options.nix on
        # the auto-provision fixpoint). CAVEAT: users.manageLingering =
        # true (nixpkgs, default false) garbage-collects linger files not
        # declared via users.users.<u>.linger — incompatible with this
        # module for gateway users; declare linger on the host account
        # there instead.
        ++ lib.optional ucfg.spacesGateway.enable "f /var/lib/systemd/linger/${user} 0644 root root - -"
      ) cfg.enabledUsers
    );

    # Netfilter marker groups (see lib.nix vmGroup): empty groups whose
    # only members are the VM units via SupplementaryGroups. Safe here —
    # users.GROUPS never feeds the users.users auto-provision scan.
    users.groups = forEachUser (
      user: _: {
        ${vmGroup user} = { };
      }
    );
  };
}
