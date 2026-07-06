# Unit check: the pi-web PWA's conversation reducer (packages/pi-web/reducer.ts).
#
# The reducer is pure (pi events -> ChatState), so this folds streamed replies,
# confirms, and sidechannel_resolved without a browser — and additionally
# replays the shared pi-event fixture corpus (checks/pi-chat-reducer/fixtures,
# also folded by the quickshell panel's Reducer.js) so the two client folds
# cannot drift apart silently. The full DOM + WS path is exercised by the
# headless-browser E2E check. ~1s.
{ pkgs, ... }:
pkgs.runCommand "pi-web-reducer-test"
  {
    nativeBuildInputs = [ pkgs.bun ];
    src = ../../packages/pi-web;
    corpusTest = ./corpus.test.ts;
    fixtures = ../pi-chat-reducer/fixtures;
  }
  ''
    set -euo pipefail
    cp -r --no-preserve=mode "$src"/. work
    cp "$corpusTest" work/corpus.test.ts
    cd work
    export HOME=$TMPDIR   # bun's transpile cache
    export PI_EVENT_FIXTURES=$fixtures
    bun test ./reducer.test.ts ./corpus.test.ts
    touch $out
  ''
