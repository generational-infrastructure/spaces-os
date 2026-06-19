# Unit check: pi-sessiond authenticates to its llama-swap endpoint.
#
# `fetchModels` (packages/pi-sessiond/provider.ts) is the boot-time model
# discovery split out of main.ts. It must send the configured llama-swap API
# key as a Bearer token so a key-protected llama-swap (the default for the
# clan `pi` service) answers discovery and completions instead of 401. Pure
# `fetch`, no pi SDK, so this asserts the auth-header contract without booting
# the daemon. ~3s.
{ pkgs, ... }:
pkgs.runCommand "pi-sessiond-provider-test"
  {
    nativeBuildInputs = [ pkgs.bun ];
    src = ../../packages/pi-sessiond;
  }
  ''
    set -euo pipefail
    cp -r "$src"/. work
    cd work
    export HOME=$TMPDIR   # bun's transpile cache
    bun test ./provider.test.ts
    touch $out
  ''
