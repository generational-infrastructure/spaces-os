# Daemon-level check: the supervisor drives a pi rpc-mode child end-to-end
# (docs/pi-runtime-isolation-refactor.md §9 step 1). The runtime-isolation
# refactor inverts pi-sessiond — it no longer embeds pi, it spawns
# `pi --mode rpc` per session and drives it over a JSON-line pipe. This boots
# the real daemon against a stub pi (SPACES_SESSIOND_PI_BIN) and asserts a turn
# round-trips and the extension_ui side-channel surfaces + resolves across the
# pipe. Real daemon, stub pi, python websockets client. No model, no VM, ~3s.
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
pkgs.runCommand "pi-sessiond-drive-path-test"
  {
    meta.platforms = [ "x86_64-linux" ];
    nativeBuildInputs = [
      py
      pkgs.coreutils
    ];
  }
  ''
    export HOME="$TMPDIR"
    export TMPDIR="$TMPDIR"
    export SPACES_SESSIOND_LANDLOCK_EXEC=${stubs.landlockExec}/bin/pi-landlock-exec
    ${py}/bin/python3 ${./driver.py} ${pkgs.lib.getExe daemon} ${stubPi} ${stubs.systemdRun}/bin/systemd-run
    touch "$out"
  ''
