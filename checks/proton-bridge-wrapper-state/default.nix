# Pins the `protonmail-bridge` wrapper's state-root choice
# (modules/nixos/proton-bridge/wrapper.nix).
#
# Every other consumer of the Bridge state root — the manifest env pin
# (SPACES_PROTON_BRIDGE_STATE in ../../modules/nixos/spaces-integrations/
# defaults.nix), the confined daemon's Landlock grant, the tmpfiles rule, and
# both Python modules — agrees on ONE directory. The wrapper is the piece that
# actually WRITES there, so it must honor the same env pin: if it derives the
# root from XDG_STATE_HOME alone, a user with XDG_STATE_HOME set gets Bridge
# state where nothing else looks (setup helper times out waiting for the
# vault, the daemon writes outside its Landlock grant).
#
# Method: build the REAL wrapper with a stub `protonmail-bridge` as the
# wrapped package (the wrapper execs it by absolute store path, so the stub
# intercepts deterministically). The stub dumps the six state-derived paths
# the wrapper exports; assert each sits under the expected root for:
#   (a) SPACES_PROTON_BRIDGE_STATE + XDG_STATE_HOME both set → env pin wins;
#   (b) only XDG_STATE_HOME set → <xdg>/protonmail-bridge (unmanaged runs);
#   (c) neither set → $HOME/.local/state/protonmail-bridge.
# The wrapper's keychain bootstrap (GPG keygen + pass init) runs for real
# against each per-case GNUPGHOME — cheap, and proves the bootstrap itself
# lands under the chosen root.
{ pkgs, ... }:
let
  # Env-dumping stand-in for the real Bridge; `lib.getExe` resolves it via
  # writeShellScriptBin's meta.mainProgram, same as the real package.
  stub = pkgs.writeShellScriptBin "protonmail-bridge" ''
    printf 'STATE_PROBE XDG_CONFIG_HOME=%s\n' "''${XDG_CONFIG_HOME-}"
    printf 'STATE_PROBE XDG_DATA_HOME=%s\n' "''${XDG_DATA_HOME-}"
    printf 'STATE_PROBE XDG_CACHE_HOME=%s\n' "''${XDG_CACHE_HOME-}"
    printf 'STATE_PROBE GNUPGHOME=%s\n' "''${GNUPGHOME-}"
    printf 'STATE_PROBE PASSWORD_STORE_DIR=%s\n' "''${PASSWORD_STORE_DIR-}"
    printf 'STATE_PROBE TMPDIR=%s\n' "''${TMPDIR-}"
  '';
  wrapper = import ../../modules/nixos/proton-bridge/wrapper.nix {
    inherit pkgs;
    package = stub;
  };
in
pkgs.runCommand "proton-bridge-wrapper-state"
  {
    meta.platforms = [ "x86_64-linux" ];
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnupg # gpgconf: reap the per-case gpg-agent so no fd outlives the build
    ];
  }
  ''
    set -euo pipefail
    export HOME="$PWD/home"
    mkdir -p "$HOME"

    # run <expected-root> [VAR=value ...] — invoke the wrapper with exactly
    # the given extra env, then assert every state-derived export sits under
    # the expected root.
    run() {
      local root probe pin
      root=$1; shift
      echo "--- expecting state root: $root (env: $*)"
      probe=$(env "$@" ${pkgs.lib.getExe wrapper})
      echo "$probe"
      GNUPGHOME="$root/gnupg" gpgconf --kill all 2>/dev/null || true
      for pin in \
        "XDG_CONFIG_HOME=$root/config" \
        "XDG_DATA_HOME=$root/data" \
        "XDG_CACHE_HOME=$root/cache" \
        "GNUPGHOME=$root/gnupg" \
        "PASSWORD_STORE_DIR=$root/password-store" \
        "TMPDIR=$root/tmp"; do
        if ! echo "$probe" | grep -qxF "STATE_PROBE $pin"; then
          echo "FAIL: wrapper did not pin $pin" >&2
          exit 1
        fi
      done
    }

    # (a) env pin beats XDG: SPACES_PROTON_BRIDGE_STATE is the full state
    # root every other consumer agrees on — it must win.
    run "$PWD/custom-root" \
      SPACES_PROTON_BRIDGE_STATE="$PWD/custom-root" \
      XDG_STATE_HOME="$PWD/xdg"

    # (b) unmanaged/manual runs: no env pin, XDG fallback stays.
    run "$PWD/xdg/protonmail-bridge" XDG_STATE_HOME="$PWD/xdg"

    # (c) bare default.
    run "$HOME/.local/state/protonmail-bridge"

    touch "$out"
  ''
