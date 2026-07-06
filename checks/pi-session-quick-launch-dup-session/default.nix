# Quick-launch duplicate-session regression.
#
# Drives the real PiChatBackend (headless quickshell) against a fake
# pi-sessiond that broadcasts the §12 `sessions` list immediately after each
# create_session ack — the exact sequence the real daemon emits. With a single
# REMOTE executor configured (injected as JSON via $SPACES_PI_CHAT_EXECUTORS,
# since the root-owned /etc/spaces/pi-chat.json can't be written in the sandbox)
# and a seeded sessions.json (the returning desktop that arms lastImportTime)
# this reproduces the duplicate-session bug: launchBackground's spawn()-then-send()
# issued a SECOND create_session while the first was in flight; the daemon
# minted two sessions, the panel entry could keep only one, and the broadcast
# re-imported the orphaned id as a dead duplicate.
#
# Asserts exactly ONE index entry after a remote double-spawn, and that the
# quick-bar session follows defaultExecutor (the lone remote here) while
# staying single through the launchBackground path too. No real pi/LLM, no
# compositor, no VM. ~10-20s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-quick-launch-dup-session";
  dir = ./.;
  qtModules = [ pkgs.qt6.qtwebsockets ];
  python = pkgs.python3.withPackages (ps: [ ps.websockets ]);
}
