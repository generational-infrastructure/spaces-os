# Daemon-level side-channel check (design §6): the REAL pi-sessiond (embedding
# pi via its SDK) against a mock LLM that emits a bash tool_call, behind a
# systemd-run stub, driven over the §12 WebSocket protocol. The tool_call is
# gated by the bundled bash-confirm extension, opening the confirm side channel.
# Asserts:
#   - first-answer-wins: two mirrored clients answer one extension_ui_request;
#     the first wins (the turn completes once); the loser gets sidechannel_resolved.
#   - park: a zero-client request marks the session `parked` (list_sessions),
#     survives, and is resolvable on re-attach.
#   - notifier: a zero-client park fires SPACES_SESSIOND_NOTIFY_CMD out-of-band.
#
# Cheap (~seconds, no VM): bun runs the daemon on loopback in the build sandbox.
# x86_64-linux only to match the other daemon checks; stub elsewhere.
{ pkgs, inputs, ... }:

if pkgs.stdenv.hostPlatform.system != "x86_64-linux" then
  pkgs.runCommand "pi-sessiond-sidechannel-x86_64-only" { } "mkdir -p $out"
else

  let
    daemon = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond;
    py = pkgs.python3.withPackages (ps: [ ps.websockets ]);

    # The confirm side-channel is driven by the bundled bash-confirm extension.
    bashConfirm = ../../modules/nixos/pi-chat/extensions/bash-confirm.ts;

    stub = pkgs.runCommandLocal "systemd-run-stub" { nativeBuildInputs = [ pkgs.bash ]; } ''
      install -Dm755 ${./systemd-run-stub} $out/bin/systemd-run
      patchShebangs $out/bin/systemd-run
    '';

    notifyStub = pkgs.runCommandLocal "notify-stub" { nativeBuildInputs = [ pkgs.python3 ]; } ''
      install -Dm755 ${./notify-stub.py} $out/bin/notify-stub
      patchShebangs $out/bin/notify-stub
    '';
  in
  pkgs.runCommand "pi-sessiond-sidechannel-test"
    {
      nativeBuildInputs = [
        py
        pkgs.coreutils
      ];
    }
    ''
      export HOME="$TMPDIR"
      ${py}/bin/python3 ${./driver.py} \
        ${pkgs.lib.getExe daemon} \
        ${./mock-llm.py} \
        ${stub}/bin/systemd-run \
        ${notifyStub}/bin/notify-stub \
        ${bashConfirm}
      touch "$out"
    ''
