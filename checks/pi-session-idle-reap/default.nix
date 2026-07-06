# WS-era idle-reap contract test.
#
# PiSession no longer spawns local pi workers — sessions live in a
# pi-sessiond executor over WebSocket, and the reaper moved with them:
# PiChatBackend._reapIdle() calls PiSession.stop() on idle *streaming*
# sessions, which emits a `detach` frame for the session's daemon id
# (plus a panel-local unsubscribe). Busy sessions and pending background
# launches are skipped — no frame at all. No systemctl anywhere.
#
# Drives the real PiChatBackend (headless quickshell) against a mock
# pi-sessiond that logs every inbound frame. Two background launches:
# one held mid-turn (the mock never sends agent_end, so the panel keeps
# busy=true), one completed (agent_end → idle but still attached). After
# backend._reapIdle() (invoked via the IPC seam, not the real timer) the
# frame log must show a detach for the idle session's daemon id and NONE
# for the busy one; panel flags agree (idle streaming=false, busy
# streaming=true). The executor is injected via $SPACES_PI_CHAT_EXECUTORS
# (the panel's test seam). No real pi/LLM/daemon, no compositor, no VM.
# ~10-20s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-idle-reap";
  dir = ./.;
  qtModules = [ pkgs.qt6.qtwebsockets ];
  python = pkgs.python3.withPackages (ps: [ ps.websockets ]);
}
