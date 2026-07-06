# Create-ack routing contract test.
#
# The panel correlates create acks by the client-minted requestId the
# daemon echoes verbatim on the created ack. A plain attach ack for a
# persisted session racing an in-flight create must never be taken for
# the create's ack — pre-fix (FIFO resolution, no correlation id) it
# was, stamping the attached session's daemon id onto the creating
# entry (two tabs sharing one daemon session). The fake daemon forces
# the racing interleave deterministically.
#
# Real PiChatBackend (headless quickshell) against a scripted python
# fake daemon. No pi, no LLM, no VM. ~5-10s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-create-ack-routing";
  dir = ./.;
  qtModules = [ pkgs.qt6.qtwebsockets ];
  python = pkgs.python3.withPackages (ps: [ ps.websockets ]);
  platforms = [ "x86_64-linux" ];
}
