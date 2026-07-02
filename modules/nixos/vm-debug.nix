# VM-only debug conveniences.
#
# Applied via virtualisation.vmVariant so they only affect builds of
# `system.build.vm` (e.g. `nix build .#test-vm`), not the installed
# system. Two display modes:
#   - GUI (default): QEMU's native GTK window, with host↔guest clipboard
#     via QEMU's built-in qemu-vdagent chardev (guest side: spice-vdagent)
#     and intel-hda duplex audio via host PipeWire. Needs a QEMU built
#     with gtk_clipboard (see the package override below); under Wayland
#     the GTK window inherits the compositor's hi-DPI scale factor.
#   - headless (services.spaces.vm-debug.headless = true): no window,
#     QMP control socket on /tmp/agent-vm-qmp.sock, VNC on
#     127.0.0.1:5999, serial on stdio. Intended for agent-driven dev
#     loops that send synthetic keys + grab screenshots over QMP.
# SSH on host:2222 → guest:22 is always on.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.services.spaces.vm-debug;
  guiOpts = [
    # `nix run .#test-vm` shows the guest in QEMU's own GTK window.
    # virtio-vga-gl + gl=on give the guest accelerated GL.
    # zoom-to-fit=off: 1 guest px = 1 logical px, so under Wayland the
    # compositor scales the window by the host's hi-DPI factor and the
    # guest renders at the size you expect (resize the window to zoom).
    "-device virtio-vga-gl"
    "-display gtk,gl=on,zoom-to-fit=off"
    "-audiodev pipewire,id=snd0"
    "-device intel-hda"
    "-device hda-duplex,audiodev=snd0"
    # Clipboard: QEMU >= 6.1 ships the HOST side of the vdagent protocol
    # as a chardev (qemu-vdagent) - no SPICE server or client involved.
    # It bridges the guest's spice-vdagent to the GTK window's clipboard
    # (the gtk_clipboard feature the override below turns on). The guest
    # side (spice-vdagent, configured below) is unchanged.
    "-device virtio-serial"
    "-chardev qemu-vdagent,id=vdagent,name=vdagent,clipboard=on"
    "-device virtserialport,chardev=vdagent,name=com.redhat.spice.0"
  ];
  # Headless: no audio, no vdagent, no GL. Paths come from the
  # agent-vm wrapper via env vars so the same VM image can run in
  # any cwd / sandbox.
  headlessOpts = [
    # No -vga: rely on QEMU's default std VGA. Bochs DRM/simpledrm
    # gives niri a card to modeset on, and screendump captures the
    # primary head. nixos-test-driver uses the same shape and
    # successfully OCRs the niri framebuffer.
    "-display none"
    "-vnc \${AGENT_VM_VNC:-127.0.0.1:99}"
    "-qmp unix:\${AGENT_VM_QMP},server=on,wait=off"
    # Persist boot/journal output to a file: pueue captures the
    # wrapper's stdout but QEMU's -serial stdio bytes never reach
    # that log, so route serial straight to $AGENT_VM_SERIAL.
    "-serial file:\${AGENT_VM_SERIAL}"
  ];
in
{
  options.services.spaces.vm-debug.headless = lib.mkEnableOption ''
    headless run of the test VM: no GTK window, QMP control socket
    at $AGENT_VM_QMP, VNC at $AGENT_VM_VNC (default 127.0.0.1:5999),
    serial on stdio. Used by `nix build .#agent-vm` for agent-driven
    dev loops'';

  config.virtualisation.vmVariant = {
    virtualisation.memorySize = 8192;
    virtualisation.cores = 8;

    virtualisation.qemu.options = if cfg.headless then headlessOpts else guiOpts;

    # The GUI variant needs QEMU's GTK clipboard bridge, which nixpkgs
    # ships disabled (upstream marks the meson feature "EXPERIMENTAL,
    # MAY HANG", https://gitlab.com/qemu-project/qemu/-/issues/1150 -
    # if a run ever wedges, suspect this first). Rebuild qemu_kvm with
    # it enabled; the headless variant keeps the stock (cached) qemu.
    virtualisation.qemu.package = lib.mkIf (!cfg.headless) (
      pkgs.qemu_kvm.overrideAttrs (old: {
        configureFlags = old.configureFlags ++ [ "--enable-gtk-clipboard" ];
      })
    );

    # GTK and headless modes use distinct host SSH ports so a developer
    # can run `nix build .#test-vm` and `nix build .#agent-vm` side by
    # side without QEMU port collisions.
    virtualisation.forwardPorts = [
      {
        from = "host";
        host.port = if cfg.headless then 2223 else 2222;
        guest.port = 22;
      }
    ];

    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = true;
      settings.PermitRootLogin = "yes";
    };

    users.mutableUsers = false;
    users.users.root.initialPassword = "root";

    # Use smallest English-only model for faster transcription in VM.
    spaces.voxtype.whisperModel = "tiny.en";
    spaces.voxtype.whisperLanguage = "en";

    # Guest-side clipboard agent only makes sense with the GUI display
    # — headless has no vdagent channel to attach to.
    services.spice-vdagentd.enable = !cfg.headless;
    systemd.user.services.spice-vdagent = lib.mkIf (!cfg.headless) {
      description = "Spice vdagent user session agent";
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.spice-vdagent}/bin/spice-vdagent -x";
      };
      wantedBy = [ "graphical-session.target" ];
    };

    # spice-vdagent is X11-only (no libwayland), so the host clipboard it
    # receives only reaches the XWayland CLIPBOARD selection — and niri's
    # xwayland-satellite does not mirror X->Wayland, so Wayland clients
    # (the quickshell panel, wl-paste) never see it. Bridge it: block on
    # X CLIPBOARD changes and copy each into the Wayland clipboard. Dedup
    # against the current Wayland value so the Wayland->X path can't loop.
    systemd.user.services.spice-clipboard-to-wayland = lib.mkIf (!cfg.headless) {
      description = "Mirror the X11 clipboard (fed by spice-vdagent) into Wayland";
      partOf = [ "graphical-session.target" ];
      after = [
        "graphical-session.target"
        "spice-vdagent.service"
      ];
      wantedBy = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 2;
        ExecStart = pkgs.writeShellScript "spice-clipboard-to-wayland" ''
          export DISPLAY=:0
          while :; do
            ${pkgs.clipnotify}/bin/clipnotify -s clipboard || { sleep 1; continue; }
            val=$(${pkgs.xclip}/bin/xclip -selection clipboard -o 2>/dev/null) || continue
            [ -n "$val" ] || continue
            cur=$(${pkgs.wl-clipboard}/bin/wl-paste -n 2>/dev/null || true)
            [ "$val" = "$cur" ] && continue
            printf %s "$val" | ${pkgs.wl-clipboard}/bin/wl-copy
          done
        '';
      };
    };

    # The reverse leg: spice-vdagent only reads the X11 CLIPBOARD, so a
    # Wayland copy in the guest (niri, the quickshell panel) never reaches
    # the host. Watch the Wayland clipboard and mirror each change into
    # X11, where spice-vdagent picks it up and forwards it to the host.
    # Dedup against the current X value so the X->Wayland path can't loop
    # ($(...) strips trailing newlines, so both directions compare equal).
    systemd.user.services.spice-clipboard-from-wayland = lib.mkIf (!cfg.headless) {
      description = "Mirror the Wayland clipboard into X11 (for spice-vdagent -> host)";
      partOf = [ "graphical-session.target" ];
      after = [
        "graphical-session.target"
        "spice-vdagent.service"
      ];
      wantedBy = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 2;
        ExecStart = "${pkgs.wl-clipboard}/bin/wl-paste --watch ${pkgs.writeShellScript "spice-clipboard-from-wayland-sync" ''
          export DISPLAY=:0
          val=$(cat) || exit 0
          [ -n "$val" ] || exit 0
          cur=$(${pkgs.xclip}/bin/xclip -selection clipboard -o 2>/dev/null || true)
          [ "$val" = "$cur" ] && exit 0
          printf %s "$val" | ${pkgs.xclip}/bin/xclip -selection clipboard -i
        ''}";
      };
    };
  };
}
