# New-chat model inheritance contract test.
#
# A brand-new chat session must default to the model the user most
# recently selected (max lastUsed in the frecency store), not to pi's
# default. PiSession is WS-only, so the inherited model must ride the
# create_session envelope itself (model="provider/id") — the daemon
# session comes up on it, race-free by construction. Entries minted
# via _freshSessionEntry (the remote-import shape) must keep model ""
# so imported daemon sessions never inherit a local pick.
#
# Headless quickshell hosting the real PiChatBackend against a mock
# pi-sessiond (injected via $SPACES_PI_CHAT_EXECUTORS) that logs every
# frame in order. No compositor, no LLM. ~10-20s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-new-chat-inherits-model";
  dir = ./.;
  qtModules = [ pkgs.qt6.qtwebsockets ];
  python = pkgs.python3.withPackages (ps: [ ps.websockets ]);
}
