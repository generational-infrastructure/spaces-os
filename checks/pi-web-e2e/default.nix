# Headless-browser E2E for the pi-web PWA. A real pi-sessiond (embedding pi via
# its SDK) serves the PWA on loopback, backed by a deterministic mock LLM;
# headless chromium loads it and a Bun CDP driver exercises the DOM: connect,
# prompt + streamed reply, and the confirm side-channel (a "confirm" prompt ->
# bash tool_call -> bash-confirm -> confirm card -> Allow). The reducer logic is
# covered by checks/pi-web-reducer and static serving by checks/pi-web-serve.
{ pkgs, inputs, ... }:
let
  sys = pkgs.stdenv.hostPlatform.system;
  daemon = inputs.self.packages.${sys}.pi-sessiond;
  web = inputs.self.packages.${sys}.pi-web;
  inherit (pkgs) chromium;
  # Headless chromium FATALs in SkFontMgr when it renders text with no fonts;
  # give it a fontconfig pointing at a single TTF.
  fontsConf = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  # The confirm side-channel is driven by the bundled bash-confirm extension.
  bashConfirm = ../../modules/nixos/pi-chat/extensions/bash-confirm.ts;

  # Stand-in for systemd-run inside the build sandbox: confines (strips to)
  # `bash -c <cmd>` for the command the confirm test allows.
  stub = pkgs.runCommandLocal "systemd-run-stub" { nativeBuildInputs = [ pkgs.bash ]; } ''
    install -Dm755 ${./systemd-run-stub} $out/bin/systemd-run
    patchShebangs $out/bin/systemd-run
  '';
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

    SPACES_SESSIOND_SYSTEMD_RUN=${stub}/bin/systemd-run \
    SPACES_SESSIOND_PI_EXTENSIONS=${bashConfirm} \
    SPACES_SESSIOND_HOST=127.0.0.1 \
    SPACES_SESSIOND_PORT=8795 \
    SPACES_SESSIOND_TOKEN=e2e-token \
    SPACES_SESSIOND_PWA_DIR=${web} \
    SPACES_SESSIOND_STATE_DIR="$TMPDIR/state" \
    LLAMA_SWAP_BASE_URL=http://127.0.0.1:8013 \
    SPACES_SESSIOND_DEFAULT_MODEL=mock-model \
    SPACES_SESSIOND_IDLE_TIMEOUT_MS=0 \
      ${pkgs.lib.getExe daemon} >"$TMPDIR/daemon.log" 2>&1 &
    daemon=$!

    if ! bun ${./e2e.ts} http://127.0.0.1:8795 e2e-token ${pkgs.lib.getExe chromium} "$TMPDIR/profile" 9333; then
      echo "=== daemon.log ==="
      cat "$TMPDIR/daemon.log" || true
      exit 1
    fi
    touch "$out"
  ''
