# VM-only debug conveniences.
#
# Applied via virtualisation.vmVariant so they only affect builds of
# `system.build.vm` (e.g. `nix build .#test-vm`), not the installed
# system. Two display modes:
#   - GTK (default): virtio-vga-gl + interactive window, spice-vdagent
#     host↔guest clipboard, intel-hda duplex audio via host PipeWire.
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
    "-device virtio-vga-gl"
    "-display gtk,gl=on,show-menubar=off"
    "-audiodev pipewire,id=snd0"
    "-device intel-hda"
    "-device hda-duplex,audiodev=snd0"
    # Clipboard sharing between host and guest.
    "-chardev qemu-vdagent,id=vdagent,name=vdagent,clipboard=on"
    "-device virtio-serial"
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
  };
}
