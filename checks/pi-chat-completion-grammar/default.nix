# Launch-bar grammar contract test.
#
# Exercises the pure parser (programs/pi-chat/BarParse.js) over the
# grammar/behaviour matrix from the launch-bar completion plan: leading
# slash-directives, the load-bearing `:`-in-value split
# (/model:gemma4:e4b → value "gemma4:e4b"), last-wins duplicates, bare
# commands, non-leading slashes as prose, and cursor-relative partials.
#
# The parser imports nothing from QML, so this needs no PiChatBackend,
# no pi worker and no mock LLM — just headless quickshell importing the
# real BarParse.js and a driver that drives parse() over IPC. ~3-5s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-chat-completion-grammar";
  dir = ./.;
}
