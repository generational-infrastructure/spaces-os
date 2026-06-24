# Two pi-sessiond daemons (alpha + beta) running on different loopback ports
# share one token; the PWA is served by alpha with both peers in its
# SPACES_SESSIOND_PEERS. Headless chromium loads the PWA and the bun driver
# proves the multi-executor wiring end-to-end: /executors discovery →
# fan-out WS to both peers → picker shows both → routed create_session →
# merged list with per-row host tags.
#
# No LLM: the daemons only need to accept hello + create_session; the reducer
# behaviour (prompts, streaming, confirm side-channel) is covered by the
# single-executor pi-web-e2e check.
{ pkgs, inputs, ... }:
let
  sys = pkgs.stdenv.hostPlatform.system;
  daemon = inputs.self.packages.${sys}.pi-sessiond;
  web = inputs.self.packages.${sys}.pi-web;
  inherit (pkgs) chromium;
  fontsConf = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  alphaPort = "8795";
  betaPort = "8796";
  alphaHost = "127.0.0.1:${alphaPort}";
  betaHost = "127.0.0.1:${betaPort}";
  peersJson = builtins.toJSON [
    {
      id = "alpha";
      host = alphaHost;
    }
    {
      id = "beta";
      host = betaHost;
    }
  ];
  # Passthrough launcher stubs (no systemd / no kernel Landlock in the build
  # sandbox); real Landlock enforcement is checks/pi-sessiond-landlock.
  stubs = import ../pi-sessiond-sidechannel/launcher-stubs.nix { inherit pkgs; };
in
pkgs.runCommand "pi-web-multi-executor-test"
  {
    meta.platforms = [ "x86_64-linux" ];
    nativeBuildInputs = [
      pkgs.bun
      chromium
      pkgs.coreutils
    ];
  }
  ''
    set -euo pipefail
    export HOME="$TMPDIR"
    export FONTCONFIG_FILE=${fontsConf}
    # Both daemons inherit the launcher from the environment.
    export SPACES_SESSIOND_LANDLOCK_EXEC=${stubs.landlockExec}/bin/pi-landlock-exec
    mkdir -p "$TMPDIR/state-alpha" "$TMPDIR/state-beta" "$TMPDIR/profile"

    # Alpha — serves the PWA, declares both peers.
    SPACES_SESSIOND_HOST=127.0.0.1 \
    SPACES_SESSIOND_PORT=${alphaPort} \
    SPACES_SESSIOND_EXECUTOR_ID=alpha \
    SPACES_SESSIOND_TOKEN=multi-token \
    SPACES_SESSIOND_PWA_DIR=${web} \
    SPACES_SESSIOND_STATE_DIR="$TMPDIR/state-alpha" \
    SPACES_SESSIOND_IDLE_TIMEOUT_MS=0 \
    SPACES_SESSIOND_PEERS=${pkgs.lib.escapeShellArg peersJson} \
    SPACES_SESSIOND_SYSTEMD_RUN=${stubs.systemdRun}/bin/systemd-run \
      ${pkgs.lib.getExe daemon} >"$TMPDIR/alpha.log" 2>&1 &
    alpha=$!

    # Beta — same token (clan-shared bearer), no PWA serving needed.
    SPACES_SESSIOND_HOST=127.0.0.1 \
    SPACES_SESSIOND_PORT=${betaPort} \
    SPACES_SESSIOND_EXECUTOR_ID=beta \
    SPACES_SESSIOND_TOKEN=multi-token \
    SPACES_SESSIOND_STATE_DIR="$TMPDIR/state-beta" \
    SPACES_SESSIOND_IDLE_TIMEOUT_MS=0 \
    SPACES_SESSIOND_SYSTEMD_RUN=${stubs.systemdRun}/bin/systemd-run \
      ${pkgs.lib.getExe daemon} >"$TMPDIR/beta.log" 2>&1 &
    beta=$!

    trap 'kill "$alpha" "$beta" 2>/dev/null || true' EXIT
    sleep 1

    if ! bun ${./multi-e2e.ts} \
        http://${alphaHost} multi-token \
        ${alphaHost} ${betaHost} \
        ${pkgs.lib.getExe chromium} "$TMPDIR/profile" 9334; then
      echo "=== alpha.log ==="; cat "$TMPDIR/alpha.log" || true
      echo "=== beta.log ===";  cat "$TMPDIR/beta.log"  || true
      exit 1
    fi
    touch "$out"
  ''
