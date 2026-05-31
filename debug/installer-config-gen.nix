# Unit test for the patched Calamares `nixos` job module.
#
# Builds the patched main.py out of the calamares-spaces-extensions
# package, drops it next to a stub `libcalamares` module, and runs the
# unittest suite. No VM, ~seconds. Tests monkeypatch `subprocess` to
# avoid needing real `pkexec` / `nixos-version` binaries (the nix build
# sandbox has no `/usr/bin/env` for shebangs anyway).
#
# Iteration loop:
#   nix build .#debug.x86_64-linux.installer-config-gen
{ pkgs, ... }:
let
  ext = pkgs.callPackage ../packages/calamares-spaces-extensions { };
in
pkgs.runCommandLocal "installer-config-gen-test"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    src = ./installer-config-gen;
  }
  ''
    cp -rT $src work
    chmod -R +w work
    install -m 0644 ${ext}/lib/calamares/modules/nixos/main.py work/main.py
    cd work
    python -m unittest test_render.py -v
    touch $out
  ''
