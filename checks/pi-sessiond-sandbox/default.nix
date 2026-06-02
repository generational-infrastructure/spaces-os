# Unit check: pi-sessiond launches each session inside a systemd-run sandbox.
#
# `buildSpawnCommand` (packages/pi-sessiond/sandbox.ts) is pure, so this asserts
# the sandbox bouquet (ProtectHome=tmpfs, narrowed BindPaths, the kernel/
# namespace protection set) without booting a VM or systemd. The cross-machine
# checks (pi-remote-session / pi-chat-remote) confirm pi still *functions*
# under the real sandbox. ~3s.
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
