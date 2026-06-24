# Daemon-level check: each Landlock session gets its OWN writable agent dir.
#
# The desktop executor confines every pi child in a per-session Landlock domain
# (docs/landlock-sandbox-design.md). Two concurrent instances must not share a
# writable HOME / PI_CODING_AGENT_DIR — settings/auth/locks live per session,
# only the long-term memory store is intentionally shared. This boots the real
# daemon under the Landlock branch (a stub launcher stands in for
# pi-landlock-exec) against a stub pi and asserts, over the WebSocket envelope
# protocol, that each session's agent dir is a distinct per-session directory
# under its own session dir, seeded with the static config, and that the emitted
# landlock policy never grants the daemon's shared `pi-agent` dir.
#
# Real daemon + stub launcher + stub pi. No model, no VM. ~3s. Real Landlock
# enforcement is covered by checks/pi-sessiond-landlock.
{ pkgs, inputs, ... }:

let
  daemon = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond;
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);
  stubPi = pkgs.writeShellScript "stub-pi" ''
    exec ${pkgs.python3}/bin/python3 ${../pi-sessiond-drive-path/stub-pi.py} "$@"
  '';
  # Passthrough launcher stubs (no systemd / no kernel Landlock in the build
  # sandbox); real Landlock enforcement is checks/pi-sessiond-landlock.
  stubs = import ../pi-sessiond-sidechannel/launcher-stubs.nix { inherit pkgs; };
  settings = pkgs.writeText "settings.json" (builtins.toJSON { extensions = [ ]; });
  confirm = pkgs.writeText "bash-confirm.json" (builtins.toJSON { allowPatterns = [ ]; });
in
pkgs.runCommand "pi-sessiond-landlock-agentdir-test"
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
    ${py}/bin/python3 ${./driver.py} ${pkgs.lib.getExe daemon} ${stubPi} ${stubs.systemdRun}/bin/systemd-run ${stubs.landlockExec}/bin/pi-landlock-exec ${settings} ${confirm}
    touch "$out"
  ''
