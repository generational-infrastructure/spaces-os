# Unit check: the supervisor's credential-injection proxy (proxy.ts) keeps the
# LLM key in the supervisor while the loop runs in the sandbox
# (docs/pi-runtime-isolation-refactor.md §6.2). Pins that the real credential is
# injected (replacing the sandbox's dummy) and the path/body/streamed response
# forward verbatim, against a stub upstream. No network. ~1s.
{ pkgs, ... }:
pkgs.runCommand "pi-sessiond-proxy-test"
  {
    nativeBuildInputs = [ pkgs.bun ];
    src = ../../packages/pi-sessiond;
  }
  ''
    set -euo pipefail
    cp -r "$src"/. work
    cd work
    export HOME=$TMPDIR   # bun's transpile cache
    bun test ./proxy.test.ts
    touch $out
  ''
