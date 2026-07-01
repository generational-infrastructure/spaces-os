# VM-only debug conveniences.
#
# Applied via virtualisation.vmVariant so they only affect builds of
# `system.build.vm` (e.g. `nix build .#test-vm`), not the installed
# system. Two display modes:
#   - GUI (default): SPICE display shown through remote-viewer, with
#     host↔guest clipboard via spice-vdagent and intel-hda duplex audio
#     via host PipeWire. (A local GTK window can't sync the clipboard —
#     nixpkgs ships QEMU's gtk_clipboard feature disabled.)
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
    # `nix run .#test-vm` shows the guest through a SPICE client
    # (remote-viewer), not a local QEMU window: QEMU's GTK clipboard
    # bridge ships disabled in nixpkgs (the gtk_clipboard meson feature,
    # flagged "EXPERIMENTAL, MAY HANG" upstream), so a GTK window can
    # never sync the host<->guest clipboard. SPICE's clipboard is a
    # separate, always-compiled path. virtio-vga-gl + SPICE gl=on give
    # the guest accelerated GL and hand the scanout to remote-viewer;
    # SPICE registers the sole host GL context, so no -display is set
    # (with SPICE on, QEMU defaults to no local window). The launcher
    # (packages/test-vm) spawns that client against the socket below and
    # tears it down when QEMU exits.
    "-device virtio-vga-gl"
    "-spice unix=on,addr=\${TEST_VM_SPICE_SOCK:-/tmp/test-vm-spice.sock},disable-ticketing=on,gl=on"
    "-audiodev pipewire,id=snd0"
    "-device intel-hda"
    "-device hda-duplex,audiodev=snd0"
    # SPICE agent channel: carries the host<->guest clipboard, bridged
    # in the guest by spice-vdagent (configured below).
    "-device virtio-serial"
    "-chardev spicevmc,id=vdagent,name=vdagent"
    "-device virtserialport,chardev=vdagent,name=com.redhat.spice.0"
  ];
  # Headless: no audio, no spice, no GL. Paths come from the
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
    # — headless has no spice channel to attach to.
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
  };
}
