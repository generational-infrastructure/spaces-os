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
  imports = [
    # AI chat Quickshell panel + loopback pi-sessiond executor
    inputs.self.nixosModules.pi-chat
    # local LLM server with bundled GGUF models
    inputs.self.nixosModules.llama-swap
    # noctalia status bar
    inputs.self.nixosModules.noctalia
    # niri scrollable-tiling Wayland compositor
    inputs.self.nixosModules.niri
    # QEMU display/audio/clipboard/SSH for nix build .#test-vm
    inputs.self.nixosModules.vm-debug
    # nix daemon settings (flakes, experimental features)
    inputs.self.nixosModules.nix
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

      - `minimal`: the shared hygienic baseline — nix settings + GC, sshd +
        hardening, sysctl net hygiene, firewall, `wait-online` off. No GUI, no
        headless-only opinions.
      - `server`: minimal + a hardened headless posture (no docs/fonts/xdg, UTC,
        no suspend, watchdogs, immutable users, …).
      - `desktop`: minimal + the GUI/agent stack (pi-chat, niri, noctalia, greetd).
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

      # userborn, guarded (impermanence / subuid ranges break its defaults).
      services.userborn.enable = lib.mkIf (
        !(
          (options.environment ? persistence)
          || (lib.any (u: u.subUidRanges != [ ] || u.autoSubUidGidRange) (lib.attrValues config.users.users))
        )
      ) (lib.mkDefault true);

      # sshd freeform settings — compared against ssh's own defaults, so noted (ssh:X).
      services.openssh.settings = {
        X11Forwarding = lib.mkDefault false; # ssh:false — kept as a safety net
        KbdInteractiveAuthentication = lib.mkDefault false; # ssh:yes
        PasswordAuthentication = lib.mkDefault false; # ssh:yes
        UseDns = lib.mkDefault false; # ssh:no
        StreamLocalBindUnlink = lib.mkDefault true; # ssh:no
      };

      # firewall on — often already upstream's default, but kept explicit as a
      # security safety-net (hence inline, not in commonDefaults / the nag).
      networking.firewall.enable = lib.mkDefault true;

      # NetworkManager's own wait-online unit (freeform sibling of the networkd one).
      systemd.services."NetworkManager-wait-online".enable = lib.mkDefault false;

      # nix daemon: auto-GC during builds (never wedge /nix/store), let the
      # builder fetch from caches, fail fast, keep more failure context.
      nix.settings = {
        min-free = lib.mkDefault (512 * 1024 * 1024);
        max-free = lib.mkDefault (3000 * 1024 * 1024);
        connect-timeout = lib.mkDefault 5;
        log-lines = lib.mkDefault 25;
        builders-use-substitutes = lib.mkDefault true;
      };

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

    # ── desktop: the GUI/agent stack (mutually exclusive with server) ──
    (lib.mkIf (cfg.profile == "desktop") {
      services.pi-chat.enable = lib.mkDefault true;
      services.spaces.niri.enable = lib.mkDefault true;
      services.noctalia.enable = lib.mkDefault true;

      services.greetd = {
        enable = lib.mkDefault true;
        settings.default_session = {
          command = lib.mkDefault "${config.programs.niri.package}/bin/niri-session";
          user = lib.mkDefault "alice";
        };
      };
    })
  ];
}
