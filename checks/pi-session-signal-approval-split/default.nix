# Signal approval-split check (migration plan step 7): the REAL pi-sessiond
# gateway driving the REAL integration-signal MCP server, proving signal's
# autoRun/confirm split end to end.
#
# checks/pi-sessiond-integration-gateway already proves the confirmPreview
# mechanism generically with a stub MCP + a `github` fixture. This check proves
# the SIGNAL-specific split: signal's real definition (autoRun =
# threads/read_thread/search/contacts/groups/note_to_self/fetch_attachment;
# confirm = send; confirmPreview.send = send_preview) against the real
# integration-signal server, itself wired to a fake signal-cli JSON-RPC daemon +
# a fixture messages.db (the same fake-daemon shape the integration's unit tests
# use). Asserts: the child spec lists signal's tools but never the gateway-only
# send_preview; `send` raises an approval carrying the real send_preview `to:`
# line as context and dispatches on approve (preview never touches the daemon);
# `threads`/`note_to_self` run unprompted; a preview error fails closed (no
# approval, the real send never reaches the daemon).
#
# Cheap (~seconds, no VM, no model). Real Landlock enforcement is
# checks/pi-sessiond-landlock. Reuses the gateway check's stub-pi and the shared
# launcher stubs. Does NOT extend checks/test-machine.nix (plan step 7).
{ pkgs, inputs, ... }:

let
  inherit (pkgs.stdenv.hostPlatform) system;
  daemon = inputs.self.packages.${system}.pi-sessiond;
  # The REAL server under test and the spaces_signal package that owns the
  # messages.db schema the driver builds fixtures with.
  integrationSignal = inputs.self.packages.${system}.integration-signal;
  signalCli = inputs.self.packages.${system}.signal-cli;
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);

  # The launcher execs SPACES_SESSIOND_PI_BIN by path; reuse the gateway check's
  # stub pi (same gateway↔extension sentinel contract) under python3.
  stubPi = pkgs.writeShellScript "stub-pi" ''
    exec ${pkgs.python3}/bin/python3 ${../pi-sessiond-integration-gateway/stub-pi.py} "$@"
  '';

  # Passthrough launcher stubs (no systemd / no kernel Landlock in the build
  # sandbox); they strip the bookkeeping flags and exec the tail unconfined.
  stubs = import ../pi-sessiond-sidechannel/launcher-stubs.nix { inherit pkgs; };
in
pkgs.runCommand "pi-session-signal-approval-split-test"
  {
    meta.platforms = [ "x86_64-linux" ];
    nativeBuildInputs = [
      py
      pkgs.coreutils
    ];
  }
  ''
    export HOME="$TMPDIR"
    # The gateway↔extension sentinel contract; stub-pi.py and driver.py read the
    # same JSON integrations.ts does instead of re-declaring the literals.
    export SPACES_INTEGRATION_WIRE=${daemon.integrationWire}
    # spaces_signal (from the spaces-signal-cli package) for the driver's fixture
    # messages.db builder; the integration server has its own closure and the
    # driver strips this from its child env.
    export PYTHONPATH="${signalCli}/${pkgs.python3.sitePackages}"
    ${py}/bin/python3 ${./driver.py} \
      ${pkgs.lib.getExe daemon} \
      ${stubPi} \
      ${pkgs.lib.getExe integrationSignal} \
      ${stubs.systemdRun}/bin/systemd-run \
      ${stubs.landlockExec}/bin/pi-landlock-exec
    touch "$out"
  ''
