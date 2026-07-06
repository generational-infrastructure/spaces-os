# Contract test: PiSession.restart() preserves the selected model across
# the WS delete+create cycle. restart() on a daemon-backed session sends
# detach + delete_session for the old daemon session id, clears the panel
# entry's daemonSessionId, then issues a fresh create_session whose
# envelope carries model="<provider>/<id>" equal to the session's
# modelPref — sessions are cheap daemon-side, so restart is delete +
# create rather than an in-place rebind, and no set_model replay is
# needed after the fact.
#
# Drives the real PiChatBackend (headless quickshell) against a mock
# pi-sessiond (injected as JSON via $SPACES_PI_CHAT_EXECUTORS) that logs
# every frame in order. Asserts detach(D1) → delete_session(D1) →
# create_session#2{model=modelPref} on the wire, and that the panel's
# index entry rebinds to the SECOND daemon id. No real pi/LLM, no
# compositor, no VM. ~10-20s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-restart-preserves-model";
  dir = ./.;
  qtModules = [ pkgs.qt6.qtwebsockets ];
  python = pkgs.python3.withPackages (ps: [ ps.websockets ]);
}
