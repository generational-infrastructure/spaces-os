# Focused daemon-level check: envelope ordering across a cold attach.
#
# The panel pipelines `attach` + session commands on one socket. A cold
# attach awaits the SDK session resume; commands dispatched concurrently
# (instead of queued behind it) bounce with "no such session" and the
# session comes up model-less and history-less — the production
# "panel shows no models after a daemon restart" wedge. Also pins:
# meta-only (turnless) sessions resurrect on attach, and errors for
# session-scoped envelopes echo the sessionId for client-side routing.
#
# Real daemon, python websockets client. No LLM, no VM, ~5s.
{ pkgs, inputs, ... }:

let
  daemon = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond;
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);
in
pkgs.runCommand "pi-sessiond-cold-attach-test"
  {
    meta.platforms = [ "x86_64-linux" ];
    nativeBuildInputs = [
      py
      pkgs.coreutils
    ];
  }
  ''
    export HOME="$TMPDIR"
    ${py}/bin/python3 ${./driver.py} ${pkgs.lib.getExe daemon}
    touch "$out"
  ''
