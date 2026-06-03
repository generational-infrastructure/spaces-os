# Headless-browser E2E for the pi-web PWA. A real pi-sessiond serves the PWA on
# loopback (fake pi behind a systemd-run stub — no real pi/LLM); headless
# chromium loads it and a Bun CDP driver exercises the DOM: connect, prompt +
# streamed reply, and a confirm side-channel (Allow). This is the CI counterpart
# to the browser-tool spot-checks; the reducer logic is covered separately by
# checks/pi-web-reducer and the static serving by checks/pi-web-serve.
#
# x86_64-linux only (matches the other daemon checks); stub elsewhere.
{ pkgs, inputs, ... }:

if pkgs.stdenv.hostPlatform.system != "x86_64-linux" then
  pkgs.runCommand "pi-web-e2e-x86_64-only" { } "mkdir -p $out"
else
  let
    sys = pkgs.stdenv.hostPlatform.system;
    daemon = inputs.self.packages.${sys}.pi-sessiond;
    web = inputs.self.packages.${sys}.pi-web;
    inherit (pkgs) chromium;
    # Headless chromium FATALs in SkFontMgr when it renders text with no fonts;
    # give it a fontconfig pointing at a single TTF.
    fontsConf = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };

    fakePi = pkgs.runCommandLocal "fake-pi" { nativeBuildInputs = [ pkgs.python3 ]; } ''
      install -Dm755 ${./fake-pi.py} $out/bin/fake-pi
      patchShebangs $out/bin/fake-pi
    '';

    stub = pkgs.runCommandLocal "systemd-run-stub" { nativeBuildInputs = [ pkgs.bash ]; } ''
      install -Dm755 ${./systemd-run-stub} $out/bin/systemd-run
      patchShebangs $out/bin/systemd-run
    '';
  in
  pkgs.runCommand "pi-web-e2e-test"
    {
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
      mkdir -p "$TMPDIR/state" "$TMPDIR/profile"

      PI_BIN=${fakePi}/bin/fake-pi \
      SPACES_SESSIOND_SYSTEMD_RUN=${stub}/bin/systemd-run \
      SPACES_SESSIOND_HOST=127.0.0.1 \
      SPACES_SESSIOND_PORT=8795 \
      SPACES_SESSIOND_TOKEN=e2e-token \
      SPACES_SESSIOND_PWA_DIR=${web} \
      SPACES_SESSIOND_STATE_DIR="$TMPDIR/state" \
      SPACES_SESSIOND_IDLE_TIMEOUT_MS=0 \
        ${pkgs.lib.getExe daemon} >"$TMPDIR/daemon.log" 2>&1 &
      daemon=$!
      trap 'kill "$daemon" 2>/dev/null || true' EXIT

      if ! bun ${./e2e.ts} http://127.0.0.1:8795 e2e-token ${pkgs.lib.getExe chromium} "$TMPDIR/profile" 9333; then
        echo "=== daemon.log ==="
        cat "$TMPDIR/daemon.log" || true
        exit 1
      fi
      touch "$out"
    ''
