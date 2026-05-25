# Builds the test-machine QEMU VM.
# Run: nix build .#test-vm && ./result/bin/run-test-machine-vm
#
# x86_64-linux only — `test-machine` is x86_64-pinned. On other
# build systems we ship a stub that explains the situation when
# `run-test-machine-vm` is invoked. Lets `nix flake check` succeed
# on aarch64 without forcing a cross-build of the x86 VM.
{ inputs, pkgs, ... }:
if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then
  inputs.self.nixosConfigurations.test-machine.config.system.build.vm
else
  pkgs.runCommand "test-vm-x86_64-only" { } ''
    mkdir -p "$out/bin"
    cat > "$out/bin/run-test-machine-vm" <<'EOF'
    #!/bin/sh
    echo "test-vm is x86_64-linux only; no aarch64 test-machine host yet." >&2
    exit 1
    EOF
    chmod +x "$out/bin/run-test-machine-vm"
  ''
