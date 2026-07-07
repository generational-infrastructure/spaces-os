# Headless check: the chat panel renders an integration tool-call approval
# (the new `approval_request` event) and replies the user's {once|session|deny}
# decision over the §12 WebSocket transport.
#
# Drives the real PiExecutor + PiSession against a fake gateway and asserts the
# bubble carries the gateway's tool/args — plus, for a confirmPreview tool, the
# untrusted `context` rendered as plain quoted text (and no bubble for a
# fail-closed preview) — and that each decision crosses the wire as an
# approval_response. The cheap per-feature counterpart to the full
# VM test — no compositor, pi, LLM, or VM. ~5s.
{ pkgs, ... }:
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-approval";
  dir = ./.;
  qtModules = [ pkgs.qt6.qtwebsockets ];
  python = pkgs.python3.withPackages (ps: [ ps.websockets ]);
}
