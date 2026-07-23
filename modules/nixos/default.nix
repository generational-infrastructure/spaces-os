# `nixosModules.default`: the required `spaces.profile` role switch. `minimal` is
# a shared hygienic baseline (nix settings + sane hygiene) that EVERY profile
# gets; `server` and `desktop` are **mutually exclusive** roles that each extend
# it. (`nixosModules.spaces` is a back-compat alias pinning profile = desktop.)
# NixOS imports can't depend on an option, so every sub-module is imported and
# gated by its own (default-off) enable from the profile below.
{ inputs, ... }:
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.spaces;

  # Introspectable defaults we flip from upstream (option path -> value, applied
  # as mkDefault). Redundancy is detected mechanically: the module warns when
  # upstream's own default (`options.<path>.default`) already equals ours, so a
  # nixpkgs bump names the entries to delete. Freeform settings and the kept
  # firewall safety-net stay inline (they have no `.default` to check).
  #
  # commonDefaults apply to EVERY profile (the `minimal` hygiene); serverDefaults
  # apply only to `server`.
  commonDefaults = {
    "services.openssh.enable" = true;
    "security.sudo.execWheelOnly" = true;
    # de-prioritise nix-daemon builds so they don't starve the machine's services.
    "nix.daemonCPUSchedPolicy" = "batch";
    "nix.daemonIOSchedClass" = "idle";
    "nix.daemonIOSchedPriority" = 7;
    # `wait-online` is a boot-hang/boot-fail footgun.
    "systemd.network.wait-online.enable" = false;
  };
  serverDefaults = {
    "documentation.enable" = false;
    "documentation.nixos.enable" = false;
    "documentation.doc.enable" = false;
    "documentation.info.enable" = false;
    "documentation.man.enable" = false;
    "fonts.fontconfig.enable" = false;
    "xdg.autostart.enable" = false;
    "xdg.icons.enable" = false;
    "xdg.menus.enable" = false;
    "xdg.mime.enable" = false;
    "xdg.sounds.enable" = false;
    "environment.stub-ld.enable" = false;
    "boot.loader.grub.configurationLimit" = 5;
    "boot.loader.systemd-boot.configurationLimit" = 5;
    "time.timeZone" = "UTC";
    "systemd.enableEmergencyMode" = false;
    "users.mutableUsers" = false;
  };
  splitPath = lib.splitString ".";
  upstreamDefault =
    path:
    (builtins.tryEval (lib.attrByPath (splitPath path ++ [ "default" ]) null options)).value or null;
  redundant = lib.attrNames (
    lib.filterAttrs (path: v: upstreamDefault path == v) (commonDefaults // serverDefaults)
  );
  applyDefaults =
    defs:
    lib.mkMerge (
      lib.mapAttrsToList (path: v: lib.setAttrByPath (splitPath path) (lib.mkDefault v)) defs
    );
in
{
  # Only the base layer is imported here — NOT the desktop/agent module tree
  # (pi-chat, llama-swap, niri, noctalia, vm-debug). Those pull heavy closures
  # (e.g. pi-chat → voxtype ASR models, unconditionally) that must never land on
  # a `server`, and NixOS imports can't be gated on the profile. So the GUI stack
  # is imported by `nixosModules.spaces` (the desktop alias) instead; `default`
  # stays lean enough for headless hosts.
  imports = [
    # nix daemon settings (flakes, features, build resilience, scheduling)
    inputs.self.nixosModules.nix
    # ── base layer (every profile): shared hygiene ──
    # serial console for emergency/cloud access (spaces.boot.consoles)
    inputs.self.nixosModules.serial
    # print the package diff on every switch/boot
    inputs.self.nixosModules.update-diff
    # prompt if deploying to a host whose hostname changed
    inputs.self.nixosModules.detect-hostname-change
    # terminfo for terminals that ssh in but aren't installed here
    inputs.self.nixosModules.terminfo
    # pinned host keys for the common git forges
    inputs.self.nixosModules.well-known-hosts
    # perl-free system (drop perl from activation, initrd, default packages)
    inputs.self.nixosModules.perlless
  ];

  options.spaces.profile = lib.mkOption {
    type = lib.types.enum [
      "minimal"
      "server"
      "desktop"
    ];
    description = ''
      Machine role. Required (no default — eval fails if unset). `server` and
      `desktop` are mutually exclusive; both extend `minimal`.

      - `minimal`: the shared hygienic baseline — nix daemon (flakes, GC, build
        scheduling), sshd + hardening, sudo, networkd, sysctl net hygiene,
        firewall, serial console, deploy diff + hostname-change guard, terminfo,
        well-known git-forge host keys. No GUI, no headless-only opinions.
      - `server`: minimal + a hardened headless posture (no docs/fonts/xdg, UTC,
        no suspend, watchdogs, immutable users, …).
      - `desktop`: minimal + the GUI/agent stack (pi-chat, niri, noctalia,
        greetd). The GUI modules live in `nixosModules.spaces` (the desktop
        alias), which imports them and sets this to `desktop` — so a full desktop
        is imported via that alias, not by setting `profile = "desktop"` on bare
        `default`.
    '';
  };

  config = lib.mkMerge [
    # ── minimal: the shared hygienic baseline (applies to every profile) ──
    (applyDefaults commonDefaults)
    {
      # nag once upstream adopts a flip, so it can be deleted from *Defaults.
      warnings =
        lib.optional (redundant != [ ])
          "spaces profile: these flips now match the upstream default — delete them: ${lib.concatStringsSep ", " redundant}";

      # userborn instead of the perl activation script, where it's known-safe.
      # The perlless profile imported above already flips it on via mkDefault, so
      # abstaining (mkIf-guarded mkDefault, as srvos does) is dead code here: the
      # unsafe cases must actively override that default. Unsafe means:
      #  - impermanence is loaded: still incompatible
      #    (nix-community/impermanence#223, open)
      #  - subuids/subgids are declared: userborn 1.0.0 manages them, but the
      #    NixOS module doesn't pass them through yet
      #  - a normal user pins a uid while another gets a dynamic one: userborn
      #    hands out dynamic uids without reserving pinned ones first, so the
      #    pinned user can silently end up missing (nikstur/userborn#59)
      services.userborn.enable =
        let
          users = lib.attrValues config.users.users;
          normal = lib.filter (u: u.isNormalUser) users;
          unsafe =
            (options.environment ? persistence)
            || lib.any (u: u.subUidRanges != [ ] || u.autoSubUidGidRange) users
            || (lib.any (u: u.uid != null) normal && lib.any (u: u.uid == null) normal);
        in
        # 900: above mkDefault so it beats perlless, below explicit user config.
        if unsafe then lib.mkOverride 900 false else lib.mkDefault true;

      # sshd freeform settings — compared against ssh's own defaults, so noted (ssh:X).
      services.openssh.settings = {
        X11Forwarding = lib.mkDefault false; # ssh:false — kept as a safety net
        KbdInteractiveAuthentication = lib.mkDefault false; # ssh:yes
        PasswordAuthentication = lib.mkDefault false; # ssh:yes
        UseDns = lib.mkDefault false; # ssh:no
        StreamLocalBindUnlink = lib.mkDefault true; # ssh:no
      };

      # sshd only reads keys NixOS manages (not user-writable ~/.ssh), unless a
      # git-forge that needs the AuthorizedKeysCommand path is running here.
      services.openssh.authorizedKeysFiles = lib.mkIf (
        !config.services.gitea.enable
        && !config.services.gitlab.enable
        && !config.services.gitolite.enable
        && !config.services.gerrit.enable
        && !config.services.forgejo.enable
      ) (lib.mkForce [ "/etc/ssh/authorized_keys.d/%u" ]);

      # networking: firewall on (security safety-net, often already upstream's
      # default), quiet refused-connection logs, networkd backend, and don't tear
      # down the network on a config switch.
      networking.firewall.enable = lib.mkDefault true;
      networking.firewall.logRefusedConnections = lib.mkDefault false;
      networking.useNetworkd = lib.mkDefault true;
      systemd.services."NetworkManager-wait-online".enable = lib.mkDefault false;
      systemd.services.systemd-networkd.stopIfChanged = false;
      systemd.services.systemd-resolved.stopIfChanged = false;

      # sudo: no per-session lecture, and enforce that execWheelOnly's rules only
      # ever grant root/wheel (a footgun otherwise).
      security.sudo.extraConfig = ''
        Defaults lecture = never
      '';
      assertions =
        let
          validUsers = users: users == [ ] || users == [ "root" ];
          validGroups = groups: groups == [ ] || groups == [ "wheel" ];
          validUserGroups = builtins.all (
            r: validUsers (r.users or [ ]) && validGroups (r.groups or [ ])
          ) config.security.sudo.extraRules;
        in
        [
          {
            assertion = config.security.sudo.execWheelOnly -> validUserGroups;
            message = "security.sudo.extraRules grants users/groups other than root/wheel while execWheelOnly is set. Loosen the rules or unset execWheelOnly.";
          }
        ];

      # zfs (inert unless a pool is configured): shared default hostId, plus
      # auto-snapshot/scrub when zfs is actually in use.
      networking.hostId = lib.mkDefault "8425e349";
      services.zfs = lib.mkIf config.boot.zfs.enabled {
        autoSnapshot.enable = lib.mkDefault true;
        autoSnapshot.monthly = lib.mkDefault 1;
        autoScrub.enable = lib.mkDefault true;
      };

      # wipe /tmp on boot.
      boot.tmp.cleanOnBoot = lib.mkDefault true;

      # sysctl network hygiene (anti-spoof / anti-redirect). (kptr_restrict is
      # already mkDefault 1 upstream.)
      boot.kernel.sysctl = {
        "net.ipv4.conf.all.rp_filter" = lib.mkDefault "1";
        "net.ipv4.icmp_echo_ignore_broadcasts" = lib.mkDefault true;
        "net.ipv4.conf.all.accept_redirects" = lib.mkDefault false;
        "net.ipv6.conf.all.accept_redirects" = lib.mkDefault false;
        "net.ipv4.conf.all.send_redirects" = lib.mkDefault false;
      };
    }

    # ── server: headless-only opinions (mutually exclusive with desktop) ──
    (lib.mkIf (cfg.profile == "server") (
      lib.mkMerge [
        (applyDefaults serverDefaults)
        {
          environment.variables.BROWSER = lib.mkDefault "echo";

          # Baseline headless toolkit (lowPrio so any explicit version wins).
          environment.systemPackages = map lib.lowPrio [
            pkgs.gitMinimal
            pkgs.curl
            pkgs.dnsutils
            pkgs.htop
            pkgs.jq
            pkgs.tmux
            # nix workflow tools
            pkgs.nixfmt-rs
            inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.fast-nix-gc
            inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.flake-fmt
          ];

          programs.vim = {
            defaultEditor = lib.mkDefault true;
          }
          // lib.optionalAttrs (options.programs.vim ? enable) {
            enable = lib.mkDefault true;
          };

          # LLMNR off (poisoning); freeform.
          services.resolved.settings.Resolve.LLMNR = lib.mkDefault "false";

          systemd = {
            sleep.settings.Sleep = {
              AllowSuspend = lib.mkDefault "no";
              AllowHibernation = lib.mkDefault "no";
            };
            settings.Manager = {
              RuntimeWatchdogSec = lib.mkDefault "15s";
              RebootWatchdogSec = lib.mkDefault "30s";
              KExecWatchdogSec = lib.mkDefault "1m";
            };
          };

          virtualisation.vmVariant.virtualisation.graphics = lib.mkDefault false;
        }
      ]
    ))

    # NOTE: the `desktop` profile's enables (pi-chat, niri, noctalia, greetd)
    # live in `nixosModules.spaces` (the desktop alias), alongside the imports of
    # the modules they enable — see the note on `imports` above.
  ];
}
