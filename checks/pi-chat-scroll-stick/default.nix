# Chat history scroll-behaviour regression test (issue #28).
#
# Embeds the real chat Panel with a stub backend and drives its history
# ListView over IPC: scroll up, then stream tokens into the newest
# bubble. The view must hold the reader's scrollback instead of snapping
# to the bottom on every token, while a bottom-pinned reader keeps
# following the newest message.
#
# No pi process, no LLM, no compositor. ~5s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-chat-scroll-stick";
  dir = ./.;
}
