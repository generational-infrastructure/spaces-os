# Headless-browser E2E for the pi-web PWA. A real pi-sessiond *supervisor*
# serves the PWA on loopback and spawns one `pi --mode rpc` child per session
# (runtime-isolation refactor: the daemon no longer embeds pi). The child runs a
# real turn against a deterministic mock LLM; headless chromium loads the PWA and
# a Bun CDP driver exercises the DOM: connect, prompt + streamed reply, and the
# confirm side-channel (a "confirm" prompt -> bash tool_call -> bash-confirm ->
# confirm card -> Allow). The reducer logic is covered by checks/pi-web-reducer
# and static serving by checks/pi-web-serve.
{ pkgs, inputs, ... }:
let
  sys = pkgs.stdenv.hostPlatform.system;
  daemon = inputs.self.packages.${sys}.pi-sessiond;
  web = inputs.self.packages.${sys}.pi-web;
  inherit (pkgs) chromium;
  # The supervisor spawns the real pi build it re-exports (passthru). This check
  # asserts LLM-facing behavior (a streamed reply, a gated bash tool_call), so it
  # must drive the real pi child against the mock — not the rpc stub.
  piBin = pkgs.lib.getExe' daemon.pi "pi";
  # Headless chromium FATALs in SkFontMgr when it renders text with no fonts;
  # give it a fontconfig pointing at a single TTF.
  fontsConf = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };

  # Extensions now load *inside* the pi child via its settings.json (the daemon
  # no longer reads SPACES_SESSIOND_PI_EXTENSIONS). The daemon stages this file
  # to the child's PI_CODING_AGENT_DIR/settings.json:
  #   - bash-confirm drives the confirm side-channel (gates every bash call);
  #   - llama-swap-discover registers provider "local" from the mock LLM at
  #     LLAMA_SWAP_BASE_URL, which the child inherits from the daemon.
  extDir = ../../modules/nixos/pi-chat/extensions;
  bashConfirm = builtins.path {
    path = extDir + "/bash-confirm.ts";
    name = "bash-confirm.ts";
  };
  llamaDiscover = builtins.path {
    path = extDir + "/llama-swap-discover.ts";
    name = "llama-swap-discover.ts";
  };
  piSettings = pkgs.writeText "pi-settings.json" (
    builtins.toJSON {
      extensions = [
        "${bashConfirm}"
        "${llamaDiscover}"
      ];
      defaultProvider = "local";
      defaultModel = "mock-model";
      quietStartup = true;
      enableInstallTelemetry = false;
    }
  );
  # Passthrough launcher stubs (no systemd / no kernel Landlock in the build
  # sandbox); real Landlock enforcement is checks/pi-sessiond-landlock.
  stubs = import ../pi-sessiond-sidechannel/launcher-stubs.nix { inherit pkgs; };
in
pkgs.runCommand "pi-web-e2e-test"
  {
    meta.platforms = [ "x86_64-linux" ];
    nativeBuildInputs = [
      pkgs.bun
      chromium
      pkgs.python3
      pkgs.coreutils
    ];
  }
  ''
    set -euo pipefail
    export HOME="$TMPDIR"
    export FONTCONFIG_FILE=${fontsConf}
    mkdir -p "$TMPDIR/state" "$TMPDIR/profile"

    python3 ${./mock-llm.py} 8013 &
    mock=$!
    daemon=
    trap 'kill "$mock" ''${daemon:-} 2>/dev/null || true' EXIT
    sleep 2  # let the mock bind before the daemon discovers /v1/models

    SPACES_SESSIOND_PI_BIN=${piBin} \
    SPACES_SESSIOND_PI_SETTINGS=${piSettings} \
    SPACES_SESSIOND_HOST=127.0.0.1 \
    SPACES_SESSIOND_PORT=8795 \
    SPACES_SESSIOND_TOKEN=e2e-token \
    SPACES_SESSIOND_PWA_DIR=${web} \
    SPACES_SESSIOND_STATE_DIR="$TMPDIR/state" \
    LLAMA_SWAP_BASE_URL=http://127.0.0.1:8013 \
    SPACES_SESSIOND_DEFAULT_MODEL=mock-model \
    SPACES_SESSIOND_IDLE_TIMEOUT_MS=0 \
    PI_OFFLINE=1 \
    PI_TELEMETRY=0 \
    SPACES_SESSIOND_SYSTEMD_RUN=${stubs.systemdRun}/bin/systemd-run \
    SPACES_SESSIOND_LANDLOCK_EXEC=${stubs.landlockExec}/bin/pi-landlock-exec \
      ${pkgs.lib.getExe daemon} >"$TMPDIR/daemon.log" 2>&1 &
    daemon=$!

    if ! bun ${./e2e.ts} http://127.0.0.1:8795 e2e-token ${pkgs.lib.getExe chromium} "$TMPDIR/profile" 9333; then
      echo "=== daemon.log ==="
      cat "$TMPDIR/daemon.log" || true
      exit 1
    fi
    touch "$out"
  ''
