# Focused daemon-level check: the selected model survives cold resume.
#
# set_model must write the session's meta sidecar (what a cold resume
# passes as --provider/--model, which overrides pi's session.jsonl
# restore) — otherwise idle GC / a daemon restart silently reverts the
# session to its create-time model under the restored chat history. Also
# pins: create_session with the panel's combined model="provider/id"
# splits it via the registry instead of treating the whole string as a
# "local" model id.
#
# Real daemon + argv-recording stub pi + a /v1/models stand-in for
# llama-swap. No LLM, no VM, ~5s.
{ pkgs, inputs, ... }:

let
  daemon = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond;
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);
  stubPi = pkgs.writeShellScript "stub-pi" ''
    exec ${pkgs.python3}/bin/python3 ${./stub-pi.py} "$@"
  '';
  # Passthrough launcher stubs (no systemd / no kernel Landlock in the build
  # sandbox); real Landlock enforcement is checks/pi-sessiond-landlock.
  stubs = import ../pi-sessiond-sidechannel/launcher-stubs.nix { inherit pkgs; };
in
pkgs.runCommand "pi-sessiond-model-persistence-test"
  {
    meta.platforms = [ "x86_64-linux" ];
    nativeBuildInputs = [
      py
      pkgs.coreutils
    ];
  }
  ''
    export HOME="$TMPDIR"
    export SPACES_SESSIOND_LANDLOCK_EXEC=${stubs.landlockExec}/bin/landlock-exec
    ${py}/bin/python3 ${./driver.py} ${pkgs.lib.getExe daemon} ${stubPi} ${stubs.systemdRun}/bin/systemd-run
    touch "$out"
  ''
