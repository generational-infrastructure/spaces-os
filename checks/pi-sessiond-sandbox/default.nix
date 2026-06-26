# Unit check: the Landlock policy/argv emitter (sandbox.ts), the pure half of
# the per-session sandbox (docs/landlock-sandbox-design.md §5/§6). Pins that
# buildLandlockPolicy emits a deny-by-default landlockconfig document with the
# expected fs/net/scope grants (and excludes the home + sibling sessions), and
# that buildLandlockUnitArgv wraps the child in the launcher + seccomp denylist,
# dropping to the configured uid/gid only in system scope. No kernel. ~1s.
{ pkgs, ... }:
pkgs.runCommand "pi-sessiond-sandbox-test"
  {
    nativeBuildInputs = [ pkgs.bun ];
    src = ../../packages/pi-sessiond;
  }
  ''
    set -euo pipefail
    cp -r "$src"/. work
    cd work
    export HOME=$TMPDIR   # bun's transpile cache
    bun test ./sandbox.test.ts
    touch $out
  ''
