# signal-cli daemon for the distro AI agent.
#
# Runs `signal-cli daemon` as a long-lived user systemd service that
# exposes a JSON-RPC interface over a unix socket at
# $XDG_RUNTIME_DIR/signal-cli/socket. The Signal account itself is
# linked (or registered) interactively by the user — the daemon picks
# up whatever identities live under ~/.local/share/signal-cli/ on
# startup. Multi-account mode (no `-a` pin) is deliberate: keeps the
# nix config free of personal phone numbers and lets a single daemon
# back several linked devices.
#
# Receive-mode is `on-start`: signal-cli begins draining incoming
# messages from the Signal server the moment the daemon comes up,
# regardless of whether any client is connected. That's the right
# default for our use case — the Signal protocol expects regular
# receives or pre-keys drift and decryption stalls, so we cannot rely
# on subscriber liveness to keep the queue moving. `--no-receive-stdout`
# silences the firehose; downstream consumers subscribe through the
# socket's `subscribeReceive` JSON-RPC method instead (the forwarder
# service that ships later).
#
# Files this module owns:
#   $XDG_RUNTIME_DIR/signal-cli/socket             (daemon JSON-RPC socket)
#   ~/.local/share/signal-cli/                     (signal-cli identity state — created by `signal-cli link`)
#   ~/.local/state/distro/signal/                  (distro-side store: message DB + forwarder state)
#
# Linking flow (one-time, must be done by the human; the agent never
# runs this):
#   $ signal-cli link -n "$(hostname)-pi"
#   <scan the printed tsdevice:/?... URL with primary Signal device>
#   $ systemctl --user restart distro-signal-cli
#
# After linking, signal-cli's data dir holds the linked-device keys
# and the daemon will see every message the primary device sees.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.distro-signal;

  socketRel = "signal-cli/socket"; # relative to $XDG_RUNTIME_DIR
  identityRel = ".local/share/signal-cli";
  storeRel = ".local/state/distro/signal";
in
{
  options.services.distro-signal = {
    enable = lib.mkEnableOption "signal-cli daemon backing the distro AI agent's Signal skill";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.signal-cli;
      defaultText = lib.literalExpression "pkgs.signal-cli";
      description = "signal-cli package to run the daemon from.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # The whole point of this module is to back the Signal skill
        # the agent invokes through the pi-chat sandbox. Without
        # pi-chat enabled, the sandboxBinds we publish below are dead
        # weight and the user almost certainly misconfigured.
        assertion = config.services.pi-chat.enable;
        message = ''
          services.distro-signal.enable = true requires services.pi-chat.enable = true.

          The signal-cli daemon exists to back the Signal skill the
          agent invokes inside the pi-chat sandbox. If you want
          signal-cli without pi-chat, install pkgs.signal-cli and
          manage the daemon yourself.
        '';
      }
    ];

    # signal-cli on PATH so the user can run the one-time link/register
    # flow and ad-hoc debugging commands (listGroups, listContacts, …)
    # against the same data dir the daemon uses.
    environment.systemPackages = [ cfg.package ];

    systemd.user.tmpfiles.rules = [
      # identity dir: 0700 so per-device keys are not world-readable.
      # signal-cli will create it itself on first link; we pre-create
      # so the mode is correct from the start.
      "d %h/${identityRel} 0700 - - -"
      # distro-side store dir for the forwarder / message DB the
      # signal skill will write to (lands in step 3).
      "d %h/${storeRel} 0700 - - -"
    ];

    systemd.user.services.distro-signal-cli = {
      description = "signal-cli daemon (distro AI agent Signal backend)";
      wantedBy = [ "default.target" ];
      after = [ "default.target" ];

      serviceConfig = {
        # `exec` so systemd reports ready when the JVM has actually
        # invoked exec(); `simple` would race subscribers that try to
        # connect before the socket is bound.
        Type = "exec";
        ExecStart = lib.concatStringsSep " " [
          (lib.getExe cfg.package)
          "daemon"
          # --socket without `=path` uses the default
          # $XDG_RUNTIME_DIR/signal-cli/socket, which RuntimeDirectory
          # below creates with the right mode.
          "--socket"
          "--receive-mode=on-start"
          "--no-receive-stdout"
        ];
        Restart = "always";
        RestartSec = 5;
        # systemd creates $XDG_RUNTIME_DIR/signal-cli/ with 0700 so
        # the socket inherits a directory only the user can traverse.
        RuntimeDirectory = "signal-cli";
        RuntimeDirectoryMode = "0700";
      };
    };

    # Expose what the pi-chat sandbox needs to talk to Signal. The
    # daemon socket and the distro-side store (where the forwarder
    # lands its SQLite in step 3) get bound RW; signal-cli's
    # attachment dir is bound RO so the agent can read images / files
    # users send without being able to clobber the cache.
    services.pi-chat.sandboxBinds = [
      {
        source = "%t/${socketRel}";
        # Daemon may not have come up yet when the panel spawns the
        # first session — `optional` keeps the sandbox starting and
        # the read CLI will surface a clear error instead.
        optional = true;
        mode = "rw";
      }
      {
        source = "%h/${storeRel}";
        mode = "rw";
      }
      {
        source = "%h/${identityRel}/attachments";
        # signal-cli only creates this dir once it has received the
        # first attachment, so it may legitimately be missing.
        optional = true;
        mode = "ro";
      }
    ];
  };
}
