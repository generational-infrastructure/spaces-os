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

  # Signal runtime layout under $XDG_RUNTIME_DIR ($XDG_RUNTIME_DIR ==
  # %t in user-systemd specifier-speak):
  #
  #   %t/spaces-signal/                  (parent, host-only)
  #     ├── sandbox/                     (bind-mounted into pi-chat)
  #     │     └── enqueue.sock           (sandbox ↔ bridge: agent sends)
  #     └── panel.sock                   (bridge ↔ chat panel: approval)
  #
  # The pi-chat sandbox bind-mounts the inner `sandbox/` directory
  # (not individual files); sockets the bridge later creates inside it
  # become visible to the sandbox automatically — same dentry from
  # both sides — so we don't depend on the bridge being up at sandbox
  # spawn time. Both dirs are created unconditionally by the
  # user-tmpfiles rules below; they stay empty on unlinked systems.
  #
  # `panel.sock` deliberately lives one level *outside* the
  # sandbox-bound directory: that's the security boundary. A
  # prompt-injected agent can write into enqueue.sock but cannot
  # reach panel.sock to mint its own approval.
  runtimeRoot = "spaces-signal";
  runtimeSandboxSubdir = "${runtimeRoot}/sandbox";

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
        # The whole point of this module is to back the Signal skill
        # the agent invokes through the pi-chat sandbox. Without
        # pi-chat enabled, the sandboxBinds we publish below are dead
        # weight and the user almost certainly misconfigured.
        assertion = config.services.pi-chat.enable;
        message = ''
          services.spaces-signal.enable = true requires services.pi-chat.enable = true.

          The signal-cli daemon exists to back the Signal skill the
          agent invokes inside the pi-chat sandbox. If you want
          signal-cli without pi-chat, install pkgs.signal-cli and
          manage the daemon yourself.
        '';
      }
    ];

    # signal-cli on PATH so the user can run the one-time link/register
    # flow and ad-hoc debugging commands (listGroups, listContacts, …)
    # against the same data dir the daemon uses. signalCliPkg also goes
    # on PATH so the user can drive the `signal` CLI from a regular
    # shell (debugging, scripting) against the same bridge sockets the
    # sandbox uses.
    environment.systemPackages = [
      cfg.package
      signalCliPkg
    ];

    systemd.user.tmpfiles.rules = [
      # identity dir: 0700 so per-device keys are not world-readable.
      # signal-cli will create it itself on first link; we pre-create
      # so the mode is correct from the start.
      "d %h/${identityRel} 0700 - - -"
      # spaces-side store dir: holds messages.db (the bridge writes,
      # the agent's `signal` CLI reads via a bind-mounted RW path).
      "d %h/${storeRel} 0700 - - -"
      # Signal runtime dirs. Both created unconditionally at session
      # start, so the pi-chat sandbox can bind-mount the inner dir as
      # a mandatory path even before the user has linked a Signal
      # account. The bridge later creates the sockets inside; a
      # directory bind-mount exposes new entries to both sides without
      # the sandbox having to be respawned. The parent dir is host-
      # only — that's where panel.sock lives, kept out of the sandbox
      # so a prompt-injected agent can't mint its own send approvals.
      "d %t/${runtimeRoot} 0700 - - -"
      "d %t/${runtimeSandboxSubdir} 0700 - - -"
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

    # Bridge: subscribes to the daemon, persists envelopes into
    # messages.db, and brokers the enqueue/approve flow over two
    # separate sockets. The enqueue socket is bind-mounted into the
    # pi-chat sandbox; the panel socket is NOT — that split is the
    # security boundary that keeps prompt-injected sends from
    # auto-approving themselves.
    systemd.user.services.spaces-signal-bridge = {
      description = "spaces signal bridge (forwarder + send broker)";
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

    # Sandbox-facing surface. **Daemon socket is deliberately absent.**
    # The bridge owns the only JSON-RPC client to signal-cli; routing
    # contacts/groups/send through the bridge keeps the human approval
    # gate as the single chokepoint. Exposing the daemon socket into
    # the sandbox would let a prompt-injected agent call `send`
    # directly and bypass the gate entirely.
    #
    # The message store is `ro`: the bridge writes from outside the
    # sandbox via direct filesystem access, the sandbox can only read.
    # That stops a compromised agent from forging inbound messages or
    # rewriting `pending_sends.state = 'sent'` to fake approval.
    services.pi-chat.sandboxBinds = [
      {
        source = "%h/${storeRel}";
        mode = "ro";
      }
      {
        source = "%h/${identityRel}/attachments";
        # signal-cli only creates this dir once it has received the
        # first attachment, so it may legitimately be missing.
        optional = true;
        mode = "ro";
      }
      {
        # The inner sandbox-visible dir, not a socket file: see the
        # layout comment near `runtimeRoot` at the top of this module.
        # Mandatory bind — the tmpfiles rules guarantee the source
        # exists at sandbox spawn time. The bridge later creates
        # enqueue.sock inside it; that socket becomes visible inside
        # the sandbox automatically because directory bind-mounts
        # share the same dentry. Critically: panel.sock lives one
        # level *up* and is therefore never exposed here.
        source = "%t/${runtimeSandboxSubdir}";
        mode = "rw";
      }
    ];

    # Skip the bash-confirm prompt for `signal …` — the bridge already
    # gates non-self-sends at panel.sock (unreachable from the
    # sandbox), and the read-only subcommands have nothing to gate.
    services.pi-chat.bashConfirm.allowPatterns = [ "^signal(\\s|$)" ];
  };
}
