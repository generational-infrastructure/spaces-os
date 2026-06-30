# Integration-gateway check (docs/agent-integrations-design.md §9.3): the REAL
# pi-sessiond supervisor's gateway, driven without a model or the real pi. A
# stub `pi --mode rpc` child forwards a tool call exactly as the bundled
# spaces-integrations extension does (extension_ui input with the
# integration-call sentinel); a stub MCP server stands in for the integration.
#
# Asserts the step-4 acceptance: discovery stages the per-session tool spec; an
# autoRun tool runs unprompted; a non-allowlisted tool raises an approval
# carrying its args; Deny never reaches the server; "for this session" runs it
# and suppresses the next prompt; a daemon with no integrations env exposes no
# tools.
# Also asserts the step-6 file-exchange wiring: an enabled integration adds its
# shared dir to the session's Landlock rw set (created by the supervisor); with
# none enabled, no such grant appears.
#
# Cheap (~seconds, no VM, no model): bun runs the daemon on loopback in the
# build sandbox and spawns the stub pi per session. Real Landlock enforcement is
# checks/pi-sessiond-landlock; real pi + the extension is exercised by the VM.
{ pkgs, inputs, ... }:

let
  daemon = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond;
  py = pkgs.python3.withPackages (ps: [ ps.websockets ]);

  # The launcher execs SPACES_SESSIOND_PI_BIN by path; wrap the stub so it runs
  # under python3 (there is no /usr/bin/env in the build sandbox).
  stubPi = pkgs.writeShellScript "stub-pi" ''
    exec ${pkgs.python3}/bin/python3 ${./stub-pi.py} "$@"
  '';

  # Passthrough launcher stubs (no systemd / no kernel Landlock in the build
  # sandbox); they strip the bookkeeping flags and exec the tail unconfined.
  stubs = import ../pi-sessiond-sidechannel/launcher-stubs.nix { inherit pkgs; };
in
pkgs.runCommand "pi-sessiond-integration-gateway-test"
  {
    meta.platforms = [ "x86_64-linux" ];
    nativeBuildInputs = [
      py
      pkgs.coreutils
    ];
  }
  ''
    export HOME="$TMPDIR"
    ${py}/bin/python3 ${./driver.py} \
      ${pkgs.lib.getExe daemon} \
      ${stubPi} \
      ${./stub-mcp.py} \
      ${stubs.systemdRun}/bin/systemd-run \
      ${stubs.landlockExec}/bin/pi-landlock-exec
    touch "$out"
  ''
