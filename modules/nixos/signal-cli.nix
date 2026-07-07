# signal-cli daemon for the spaces AI agent.
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
#   ~/.local/state/spaces/signal/                  (spaces-side store: message DB + forwarder state)
#
# Linking flow (one-time, must be done by the human; the agent never
# runs this):
#   $ signal-cli link -n "spaces-$(hostname)"
#   <scan the printed tsdevice:/?... URL with primary Signal device>
#   $ systemctl --user restart spaces-signal-cli
#
# After linking, signal-cli's data dir holds the linked-device keys
# and the daemon will see every message the primary device sees.
{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.spaces-signal;

  signalCliPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.signal-cli;

  identityRel = ".local/share/signal-cli";
  storeRel = ".local/state/spaces/signal";

  # systemd condition + path-unit glob. signal-cli writes per-account
  # state into ~/.local/share/signal-cli/data/<account-id>{,.d}; the
  # exact <account-id> naming varies by signal-cli version (older
  # builds use `+<phone-number>`, newer ones use opaque numeric IDs),
  # but the `.d/` per-account directory is created in both cases
  # only after a successful link/register. accounts.json exists from
  # first run with an empty array, so it can't be the signal.
  linkedAccountGlob = "%h/${identityRel}/data/*.d";
in
{
  options.services.spaces-signal = {
    enable = lib.mkEnableOption "signal-cli daemon backing the spaces AI agent's Signal skill" // {
      # Tracks pi-chat: this module is imported only by pi-chat, so
      # every pi-chat consumer gets the signal infrastructure for
      # free. The *units* stay condition-gated below, so a fresh
      # system pays nothing until the user runs `signal-cli link`.
      # Tracking (rather than a flat `true`) keeps the module inert
      # when pi-chat is imported but disabled, instead of tripping
      # the pi-chat-required assertion below.
      default = config.services.pi-chat.enable;
      defaultText = lib.literalExpression "config.services.pi-chat.enable";
    };

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
        # The whole point of this module is to feed messages.db for the
        # integration-signal MCP server, which pi-chat wires up. Without
        # pi-chat enabled, the daemon + forwarder run but nothing consumes
        # the store — the user almost certainly misconfigured.
        # `or false` keeps the failure a clean assertion (with the message
        # below) rather than an uncatchable "attribute 'pi-chat' missing"
        # when the pi-chat module isn't imported at all.
        assertion = config.services.pi-chat.enable or false;
        message = ''
          services.spaces-signal.enable = true requires services.pi-chat.enable = true.

          The signal-cli daemon + bridge exist to feed the message store
          the integration-signal MCP server (enabled through pi-chat)
          reads. If you want signal-cli without pi-chat, install
          pkgs.signal-cli and manage the daemon yourself.
        '';
      }
    ];

    # signal-cli on PATH so the user can run the one-time link/register
    # flow and ad-hoc debugging commands (listGroups, listContacts, …)
    # against the same data dir the daemon uses (plan decision 14; the
    # agent-facing surface moved to the integration-signal MCP server).
    environment.systemPackages = [ cfg.package ];

    systemd.user.tmpfiles.rules = [
      # identity dir: 0700 so per-device keys are not world-readable.
      # signal-cli will create it itself on first link; we pre-create
      # so the mode is correct from the start.
      "d %h/${identityRel} 0700 - - -"
      # spaces-side store dir: holds messages.db, written here by the bridge
      # and read (mode=ro) by the integration-signal MCP server.
      "d %h/${storeRel} 0700 - - -"
    ];

    # Daemon unit. Condition-gated on the account dir so a fresh
    # system without a linked Signal device doesn't spin up a JVM
    # at every login — the unit reports `condition: skipped` and
    # exits 0 immediately. Once the user runs `signal-cli link`,
    # the path-activation unit below triggers this service and the
    # condition passes on every subsequent login.
    systemd.user.services.spaces-signal-cli = {
      description = "signal-cli daemon (spaces AI agent Signal backend)";
      wantedBy = [ "default.target" ];
      after = [ "default.target" ];

      unitConfig.ConditionPathExistsGlob = linkedAccountGlob;

      serviceConfig = {
        # `exec` so systemd reports ready when the JVM has actually
        # invoked exec(); `simple` would race subscribers that try
        # to connect before the socket is bound.
        Type = "exec";
        ExecStart = lib.concatStringsSep " " [
          (lib.getExe cfg.package)
          "daemon"
          # --socket without `=path` uses the default
          # $XDG_RUNTIME_DIR/signal-cli/socket, which
          # RuntimeDirectory below creates with the right mode.
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

    # Bridge: subscribes to the signal-cli daemon and forwards every
    # incoming envelope into messages.db. Send + approval now live in the
    # integration-signal MCP server (gateway confirm), so the bridge owns
    # no sockets — it is purely a daemon → messages.db forwarder.
    systemd.user.services.spaces-signal-bridge = {
      description = "spaces signal bridge (signal-cli daemon → messages.db forwarder)";
      # wantedBy includes the daemon service so path-activation
      # propagates: when the daemon is started by the path unit on
      # first link, systemd pulls the bridge in too. The
      # default.target entry covers the normal login start-up path
      # for already-linked systems.
      wantedBy = [
        "default.target"
        "spaces-signal-cli.service"
      ];
      after = [
        "default.target"
        "spaces-signal-cli.service"
      ];
      requires = [ "spaces-signal-cli.service" ];

      unitConfig.ConditionPathExistsGlob = linkedAccountGlob;

      serviceConfig = {
        Type = "exec";
        ExecStart = "${signalCliPkg}/bin/spaces-signal-bridge";
        Restart = "always";
        RestartSec = 3;
      };
    };

    # Path-activation: signal-cli's `link` (and `register`) write
    # the account file into ~/.local/share/signal-cli/data/+<phone>;
    # this unit watches for that and triggers the daemon
    # automatically on first link. Without it the user would have
    # to run `systemctl --user start spaces-signal-cli` themselves.
    # The bridge follows via wantedBy on the daemon above.
    systemd.user.paths.spaces-signal-link = {
      description = "Trigger signal-cli daemon when a Signal account is linked";
      wantedBy = [ "default.target" ];
      pathConfig = {
        PathExistsGlob = linkedAccountGlob;
        Unit = "spaces-signal-cli.service";
      };
    };

  };
}
