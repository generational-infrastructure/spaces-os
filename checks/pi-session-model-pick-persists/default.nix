# Contract test: a model picked in the panel's header combobox persists.
#
# PiSession.setModel (the Panel's fire-and-forget picker path) must write
# the pick through to the session ENTRY (entry.model) — the durable
# carrier the reconciler re-asserts modelPref from on every sessionsList
# reassignment and the only thing sessions.json persists. Without the
# write-through, any list reassignment (new chat, unread bump) silently
# reverts the live session to the stale entry model, and a panel restart
# runs the default model under the restored chat history.
#
# Drives the real PiChatBackend (headless quickshell) against the mock
# pi-sessiond shared with the restart-preserves-model check. No real
# pi/LLM, no compositor, no VM. ~10-20s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-model-pick-persists";
  dir = ./.;
  qtModules = [ pkgs.qt6.qtwebsockets ];
  python = pkgs.python3.withPackages (ps: [ ps.websockets ]);
  extraArgs = [ "${../pi-session-restart-preserves-model/mock-daemon.py}" ];
}
