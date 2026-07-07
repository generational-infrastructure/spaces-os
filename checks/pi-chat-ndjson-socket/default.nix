# Contract test for NdjsonSocket.qml — the one shared unix-socket
# adapter behind PiChatBackend's skill-config sidecar, IntegrationsBridge
# and OpenUrlListener.
#
# Drives both client modes against in-driver python socket fixtures:
#   subscribe — hello line on connect, line-buffered JSON delivery,
#               bad-line rejection, send(), reconnect with backoff
#               after the peer vanishes, backoff reset on success;
#   request   — one-shot connect→send→single reply→close, malformed
#               reply, reply timeout, close-without-reply.
#
# No pi, no LLM, no compositor. ~5-10s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-chat-ndjson-socket";
  dir = ./.;
}
