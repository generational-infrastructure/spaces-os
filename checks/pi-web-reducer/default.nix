# Unit check: the pi-web PWA's conversation reducer (packages/pi-web/reducer.ts).
#
# The reducer is pure (pi events -> ChatState), so this folds streamed replies,
# confirms, and sidechannel_resolved without a browser. The full DOM + WS path
# is exercised by the headless-browser E2E check. ~1s.
{ pkgs, ... }:
pkgs.runCommand "pi-web-reducer-test"
  {
    nativeBuildInputs = [ pkgs.bun ];
    src = ../../packages/pi-web;
  }
  ''
    set -euo pipefail
    cp -r "$src"/. work
    cd work
    export HOME=$TMPDIR   # bun's transpile cache
    bun test ./reducer.test.ts
    touch $out
  ''
