# Check: the daemon serves the bundled pi-web PWA on its own port (HTTP GET),
# alongside the WS protocol. Starts the real daemon with SPACES_SESSIOND_PWA_DIR
# pointed at the pi-web package and asserts the assets + SPA fallback. No pi/LLM
# (serving is independent of sessions); ~2s.
{ pkgs, inputs, ... }:
let
  sys = pkgs.stdenv.hostPlatform.system;
  daemon = inputs.self.packages.${sys}.pi-sessiond;
  web = inputs.self.packages.${sys}.pi-web;
in
pkgs.runCommand "pi-web-serve-test"
  {
    nativeBuildInputs = [ pkgs.bun ];
  }
  ''
    set -euo pipefail
    export HOME="$TMPDIR"
    SPACES_SESSIOND_HOST=127.0.0.1 \
    SPACES_SESSIOND_PORT=8790 \
    SPACES_SESSIOND_TOKEN=serve-test \
    SPACES_SESSIOND_PWA_DIR=${web} \
    SPACES_SESSIOND_STATE_DIR="$TMPDIR/state" \
      ${pkgs.lib.getExe daemon} &
    daemon=$!
    trap 'kill "$daemon" 2>/dev/null || true' EXIT
    bun ${./check.ts} http://127.0.0.1:8790
    touch "$out"
  ''
