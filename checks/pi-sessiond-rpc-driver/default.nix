# Unit check: the supervisor's RpcDriver drives a headless pi child over the
# JSON-line pipe (docs/pi-runtime-isolation-refactor.md §3). The driver is the
# entire trusted control surface over the sandboxed runtime, so its transport —
# id-correlated responses, the event stream, and the extension_ui side-channel —
# is pinned here against a stub pi (rpc-driver.fixture.ts). No model, no
# network, ~1s.
{ pkgs, ... }:
pkgs.runCommand "pi-sessiond-rpc-driver-test"
  {
    nativeBuildInputs = [ pkgs.bun ];
    src = ../../packages/pi-sessiond;
  }
  ''
    set -euo pipefail
    cp -r "$src"/. work
    cd work
    export HOME=$TMPDIR   # bun's transpile cache
    bun test ./rpc-driver.test.ts
    touch $out
  ''
