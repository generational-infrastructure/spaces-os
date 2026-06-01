# One-shot user-state migration for the 2026-05 'distro' → 'spaces' rename.
#
# The rename commit moved every persistent on-disk path from
# ~/.local/state/distro/ and ~/.local/share/distro/ to the matching
# spaces/ location but did **not** carry existing data across. Users
# who linked Signal, ran chats, or accumulated memory before the
# rename ended up with empty new directories and orphaned state under
# distro/.
#
# This module owns the recovery: a tiny user systemd oneshot
# (spaces-state-migrate.service) running `spaces-state-migrate` at
# login, ordered Before= every service that opens a state file, so
# bridges/daemons see the migrated content from their very first
# read. RemainAfterExit=yes + Restart=no keep it idempotent: a re-run
# on a host with no legacy state is a sub-second no-op (the Python
# helper short-circuits on missing inputs).
#
# Files this module owns:
#   $HOME/.local/state/spaces/...   (destination layout, written by other modules)
#   $HOME/.local/state/distro/...   (consumed and removed when present)
#   $HOME/.local/share/spaces/...   (destination)
#   $HOME/.local/share/distro/...   (consumed and removed when present)
#
# The migration intentionally lives in its own module rather than
# inside pi-chat / signal-cli so it can sit `Before=` every consumer
# in one place and so subsystems opting in independently still get
# the same recovery semantics.
{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.spaces-state-migrate;
  migratePkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.spaces-state-migrate;
in
{
  options.services.spaces-state-migrate = {
    enable = lib.mkEnableOption "spaces user-state migration oneshot" // {
      # Tracks pi-chat: every host that boots into the Spaces bundle
      # already has the source of the rename damage installed, so the
      # migration belongs with it. The service itself only fires when
      # legacy state is actually present (ConditionPathExists below).
      default = config.services.pi-chat.enable or false;
      defaultText = lib.literalExpression "config.services.pi-chat.enable";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      # `spaces-state-migrate` on PATH so the user can also invoke the
      # migration by hand (e.g. after closing pi-chat) instead of
      # waiting for the next login.
      migratePkg
    ];

    systemd.user.services.spaces-state-migrate = {
      description = "Migrate distro → spaces user state (one-shot, idempotent)";
      # default.target is the right anchor for "runs once per user
      # login session" — early enough that the consumers below order
      # *After* us via the Before= line.
      wantedBy = [ "default.target" ];
      after = [ "default.target" ];

      # ConditionPathExists with %h means "only run when this user
      # actually has legacy state on disk." A fresh install never
      # touches the migration. The two paths are OR'd by systemd:
      # presence of either triggers the unit (we list both because
      # the rename touched both ~/.local/state and ~/.local/share).
      unitConfig.ConditionPathExists = [
        "%h/.local/state/distro"
        "%h/.local/share/distro"
      ];

      # Before= every consumer that opens a state file. The signal
      # bridge already runs its own embedded migration as a fallback
      # (defence in depth — see spaces_signal.db.migrate_legacy_state),
      # but ordering still matters for pi-chat which has no such
      # fallback: if the panel comes up first it'll write into the
      # fresh sessions.json and confuse our JSON merge.
      before = [
        "pi-chat.service"
        "spaces-signal-bridge.service"
        "spaces-signal-cli.service"
        "spaces-skill-config-daemon.service"
      ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe migratePkg;
        # The migration is fast (~tens of ms on a populated $HOME) but
        # if anything goes wrong we want to know in the journal rather
        # than silently swallow it; do NOT set RemainAfterExit=true
        # here because that would mask a future re-run after a manual
        # restore of distro/ state.
      };
    };
  };
}
