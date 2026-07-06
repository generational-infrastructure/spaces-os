# Headless check: a create_session lost to a connection flap is retried.
#
# Runs the real PiExecutor + PiSession (WS mode) against a fake pi-sessiond
# that drops the first create_session mid-flight (no ack) and accepts it only
# on reconnect — the boot-time flap the real daemon shows while coming up. A
# single send()'s prompt must survive the flap: the panel reconnects, RETRIES
# the create, attaches, and flushes the buffered prompt so the reply streams.
#
# Guards the failure mode a spawn-idempotency guard invites: with repeat
# spawns coalesced onto one in-flight create, the retry must live in the
# create path itself (_wsCreate) or the prompt sits buffered forever. The
# heavy pi-chat-remote VM test otherwise catches this only under a real boot
# flap. No compositor, pi, LLM, or VM. ~5s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-ws-create-retry";
  dir = ./.;
  qtModules = [ pkgs.qt6.qtwebsockets ];
  python = pkgs.python3.withPackages (ps: [ ps.websockets ]);
}
