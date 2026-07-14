{ pkgs, ... }:
# The standalone confirm popup (docs/agent-integrations-generic-mcp-design.md §3):
# the aggregating gateway's DEFAULT confirm command. A self-contained quickshell
# app (no harness QML) that reads the request from SPACES_CONFIRM_REQUEST and
# writes a verdict token (once|session|deny) to SPACES_CONFIRM_VERDICT_FILE.
let
  qml = pkgs.runCommandLocal "spaces-integration-confirm-qml" { } ''
    mkdir -p "$out"
    cp ${../../programs/spaces-integration-confirm/shell.qml} "$out/shell.qml"
  '';
in
pkgs.writeShellScriptBin "spaces-integration-confirm" ''
  exec ${pkgs.quickshell}/bin/quickshell -p ${qml} "$@"
''
