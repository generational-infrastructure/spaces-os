# Focused daemon-level check: the §12 `sessions` envelope is *pushed*
# unsolicited to every authenticated client on list-shaping transitions
# (create_session, gcSession, cold→live attach).
#
# Two clients A + B against the real daemon. A creates; B asserts it received
# an unsolicited `sessions` envelope containing the new id without ever
# having sent `list_sessions`. No LLM, no VM, ~2-3s.
{ pkgs, inputs, ... }:

let
  daemon = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond;
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);
  # Supervisor-side push behavior only; a stub pi child suffices.
  stubPi = pkgs.writeShellScript "stub-pi" ''
    exec ${pkgs.python3}/bin/python3 ${../pi-sessiond-drive-path/stub-pi.py} "$@"
  '';
  # Passthrough launcher stubs (no systemd / no kernel Landlock in the build
  # sandbox); real Landlock enforcement is checks/pi-sessiond-landlock.
  stubs = import ../pi-sessiond-sidechannel/launcher-stubs.nix { inherit pkgs; };
in
pkgs.runCommand "pi-sessiond-sessions-push-test"
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
    ${py}/bin/python3 ${./driver.py} ${pkgs.lib.getExe daemon} ${stubPi} ${stubs.systemdRun}/bin/systemd-run
    touch "$out"
  ''
