# Unit check: pi-sessiond's template staging survives daemon restarts.
#
# `stageFile` (packages/pi-sessiond/staging.ts) seeds settings.json /
# bash-confirm.json from read-only Nix store templates. A naive copy
# preserves the store's 0444 mode, so the second daemon start hits
# EACCES on the leftover file and the unit crash-loops (seen in
# production with restart counter 88). This pins the contract:
# staging is idempotent and replaces stale read-only residue. ~3s.
{ pkgs, ... }:
pkgs.runCommand "pi-sessiond-staging-test"
  {
    nativeBuildInputs = [ pkgs.bun ];
    src = ../../packages/pi-sessiond;
  }
  ''
    set -euo pipefail
    cp -r "$src"/. work
    cd work
    export HOME=$TMPDIR   # bun's transpile cache
    bun test ./staging.test.ts
    touch $out
  ''
