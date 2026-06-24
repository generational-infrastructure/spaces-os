# Daemon-level side-channel check (design §6): the REAL pi-sessiond supervisor
# drives a stub `pi --mode rpc` child (SPACES_SESSIOND_PI_BIN) over the rpc pipe,
# exercised over the §12 WebSocket protocol. The runtime-isolation refactor means
# the daemon no longer embeds pi — a prompt whose message contains CONFIRM makes
# the stub child emit an extension_ui_request and wait for the answer, opening the
# confirm side channel this test drives. Asserts:
#   - first-answer-wins: two mirrored clients answer one extension_ui_request;
#     the first wins (the turn completes once); the loser gets sidechannel_resolved.
#   - park: a zero-client request marks the session `parked` (list_sessions),
#     survives, and is resolvable on re-attach.
#   - notifier: a zero-client park fires SPACES_SESSIOND_NOTIFY_CMD out-of-band.
#
# Cheap (~seconds, no VM, no model): bun runs the daemon on loopback in the build
# sandbox and spawns the stub pi per session.
{ pkgs, inputs, ... }:

let
  daemon = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond;
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);

  # Reused stub `pi --mode rpc`: a prompt containing CONFIRM emits an
  # extension_ui_request and defers agent_end until the answer crosses back.
  stubPi = pkgs.writeShellScript "stub-pi" ''
    exec ${pkgs.python3}/bin/python3 ${../pi-sessiond-drive-path/stub-pi.py} "$@"
  '';

  notifyStub = pkgs.runCommandLocal "notify-stub" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    install -Dm755 ${./notify-stub.py} $out/bin/notify-stub
    patchShebangs $out/bin/notify-stub
  '';

  # Passthrough launcher stubs (no systemd / no kernel Landlock in the build
  # sandbox); real Landlock enforcement is checks/pi-sessiond-landlock.
  stubs = import ./launcher-stubs.nix { inherit pkgs; };
in
pkgs.runCommand "pi-sessiond-sidechannel-test"
  {
    meta.platforms = [ "x86_64-linux" ];
    nativeBuildInputs = [
      py
      pkgs.coreutils
    ];
  }
  ''
    export HOME="$TMPDIR"
    export SPACES_SESSIOND_LANDLOCK_EXEC=${stubs.landlockExec}/bin/pi-landlock-exec
    ${py}/bin/python3 ${./driver.py} \
      ${pkgs.lib.getExe daemon} \
      ${stubPi} \
      ${notifyStub}/bin/notify-stub \
      ${stubs.systemdRun}/bin/systemd-run
    touch "$out"
  ''
