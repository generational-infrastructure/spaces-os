# Cheap nix-eval contract for the hardened `server` profile
# (nixosModules.server).
#
# These are the defaults the profile exists to guarantee — the ones a
# careless edit could silently flip, locking you out or un-hardening a
# box. Everything is read straight off `config` (no toplevel build, so
# no SSH-key lockout assertion to satisfy), which keeps this in the
# ~seconds-to-eval bucket alongside the other *-nix-eval checks.
#
# What is NOT tested here: one-line option passthroughs whose breakage
# a real `nix build` of a host would catch anyway (boot generation
# limits, ldso stubs, zfs autosnapshot). This check guards behaviour
# and contract, not every assignment.
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;

  mkSystem =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      specialArgs = {
        inherit inputs;
        flake = inputs.self;
      };
      modules = [
        {
          nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          boot.loader.grub.enable = false;
          system.stateVersion = "26.05";
        }
        inputs.self.nixosModules.server
      ]
      ++ extra;
    };

  # A normally-configured server: a host that sets its own hostname.
  srv = (mkSystem [ { networking.hostName = "srv-test"; } ]).config;

  # A server that does NOT set a hostname — exercises the
  # `mkOverride 1337 ""` delegation default (dhcp/cloud-init owns it).
  srvNoHost = (mkSystem [ ]).config;

  yn = b: if b then "yes" else "no";
in
pkgs.runCommand "server-profile-nix-eval"
  {
    # SSH / auth hardening
    sshdEnable = yn srv.services.openssh.enable;
    passwordAuth = yn srv.services.openssh.settings.PasswordAuthentication;
    x11Forwarding = yn srv.services.openssh.settings.X11Forwarding;
    authorizedKeysFiles = lib.concatStringsSep " " srv.services.openssh.authorizedKeysFiles;

    # sudo
    execWheelOnly = yn srv.security.sudo.execWheelOnly;
    wheelNeedsPassword = yn srv.security.sudo.wheelNeedsPassword;

    # users / firewall / time
    mutableUsers = yn srv.users.mutableUsers;
    userborn = yn srv.services.userborn.enable;
    firewall = yn srv.networking.firewall.enable;
    inherit (srv.time) timeZone;

    # docs off by default, toggle exposed
    docsEnable = yn srv.documentation.nixos.enable;

    # resilience
    emergencyMode = yn srv.systemd.enableEmergencyMode;
    runtimeWatchdog = srv.systemd.settings.Manager.RuntimeWatchdogSec;

    # serial console wired into the kernel cmdline
    kernelParams = lib.concatStringsSep " " srv.boot.kernelParams;
    consoles = lib.concatStringsSep " " srv.spaces.server.consoles;

    # hostname delegation
    hostNameSet = srv.networking.hostName;
    hostNameDefault = srvNoHost.networking.hostName;

    # bundle boundary: the server profile must NOT drag in the desktop
    # bits that nixosModules.spaces ships.
    greetdEnable = yn (srv.services.greetd.enable or false);
    piChatEnable = yn (srv.services.pi-chat.enable or false);
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }

    # ── SSH / auth ──────────────────────────────────────────────────
    [ "$sshdEnable"   = "yes" ] || fail "sshd must be enabled on a server"
    [ "$passwordAuth" = "no"  ] || fail "SSH password auth must be off (keys only)"
    [ "$x11Forwarding" = "no" ] || fail "SSH X11 forwarding must be off"
    # No git-forge here, so keys come only from the system dir.
    [ "$authorizedKeysFiles" = "/etc/ssh/authorized_keys.d/%u" ] \
      || fail "authorizedKeysFiles must be locked to the system dir (got: $authorizedKeysFiles)"

    # ── sudo ────────────────────────────────────────────────────────
    [ "$execWheelOnly"      = "yes" ] || fail "sudo execWheelOnly must be on"
    [ "$wheelNeedsPassword" = "no"  ] || fail "wheel sudo must be passwordless (keys-only login)"

    # ── users / firewall / time ─────────────────────────────────────
    [ "$mutableUsers" = "no"  ] || fail "users.mutableUsers must be false"
    [ "$userborn"     = "yes" ] || fail "userborn must be enabled by default"
    [ "$firewall"     = "yes" ] || fail "firewall must be enabled"
    [ "$timeZone"     = "UTC" ] || fail "default timezone must be UTC (got: $timeZone)"

    # ── docs ────────────────────────────────────────────────────────
    [ "$docsEnable" = "no" ] || fail "NixOS docs must default off on a server"

    # ── resilience ──────────────────────────────────────────────────
    [ "$emergencyMode"   = "no"  ] || fail "emergency mode must be disabled on headless boxes"
    [ "$runtimeWatchdog" = "15s" ] || fail "RuntimeWatchdogSec must default to 15s (got: $runtimeWatchdog)"

    # ── serial console ──────────────────────────────────────────────
    case " $consoles " in
      *" ttyS0,115200 "*) ;;
      *) fail "spaces.server.consoles must include ttyS0,115200 (got: $consoles)" ;;
    esac
    case " $kernelParams " in
      *" console=ttyS0,115200 "*) ;;
      *) fail "serial console not wired into boot.kernelParams (got: $kernelParams)" ;;
    esac

    # ── hostname delegation ─────────────────────────────────────────
    [ "$hostNameSet"     = "srv-test" ] || fail "a host that sets networking.hostName must win over the profile default"
    [ -z "$hostNameDefault" ] || fail "with no host hostname the profile must leave it empty for dhcp/cloud-init (got: $hostNameDefault)"

    # ── bundle boundary ─────────────────────────────────────────────
    [ "$greetdEnable" = "no" ] || fail "the server profile must not enable greetd (desktop autologin)"
    [ "$piChatEnable" = "no" ] || fail "the server profile must not pull in the pi-chat panel"

    touch "$out"
  ''
