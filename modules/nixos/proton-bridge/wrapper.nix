# Env-pinned `protonmail-bridge` wrapper, shared by the resurrected
# spaces-proton-bridge daemon module (./default.nix) and the Proton integration
# manifest (../spaces-integrations/defaults.nix).
#
# A PURE function of `pkgs` — deliberately NOT a NixOS module — so defaults.nix
# can build the exact same wrapper derivation WITHOUT reading
# `config.services.spaces-proton-bridge` (the isolated integration eval checks
# build a system from `nixosModules.spaces-integrations` alone, where that
# option would not resolve). Mirrors the ../spaces-integrations/lib.nix
# precedent: a relative-path pure helper imported by both a module and the
# checks.
#
# Bridge determinism (local://proton-bridge-facts.md): Bridge's keychain picker
# prefers `pass` whenever the `pass` binary is on PATH (proton-bridge
# pkg/keychain/helper_linux.go `listHelpers`). We pin a dedicated
# passphraseless-GPG `pass` store under the state root and unset
# DBUS_SESSION_BUS_ADDRESS, so the (greetd-locked) gnome-keyring can never be
# selected and the vault key always lands in our store. Every Bridge / GPG /
# pass path redirects under ~/.local/state/protonmail-bridge, confining all
# Bridge state to one user-owned, wipe-to-reset directory.
#
# ONE wrapper serves BOTH callers: the daemon extraService execs it with
# `--noninteractive`; the setup helper spawns a transient `protonmail-bridge
# --grpc` by resolving `protonmail-bridge` on PATH — so the wrapper MUST be
# named `protonmail-bridge`. The real binary is exec'd by absolute store path,
# so the wrapper never recurses into itself.
{
  pkgs,
  lib ? pkgs.lib,
  package ? pkgs.protonmail-bridge,
}:
pkgs.writeShellApplication {
  name = "protonmail-bridge";
  runtimeInputs = [
    package
    pkgs.pass
    pkgs.gnupg
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gawk
  ];
  text = ''
    # Pin every Bridge / GPG / pass path under one user-owned state root and
    # drop the session bus so Bridge deterministically selects the `pass`
    # keychain (facts doc: pass-keychain determinism).
    state="''${XDG_STATE_HOME:-$HOME/.local/state}/protonmail-bridge"
    export XDG_CONFIG_HOME="$state/config"
    export XDG_DATA_HOME="$state/data"
    export XDG_CACHE_HOME="$state/cache"
    export GNUPGHOME="$state/gnupg"
    export PASSWORD_STORE_DIR="$state/password-store"
    unset DBUS_SESSION_BUS_ADDRESS

    # Idempotent keychain bootstrap: a passphraseless GPG key + `pass init`
    # when missing. A cheap no-op on every later start (two list/test probes),
    # so both the Restart=always daemon and the transient --grpc setup spawn can
    # call through unconditionally.
    install -d -m0700 "$state" "$GNUPGHOME"
    if ! gpg --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec:'; then
      gpg --batch --pinentry-mode loopback --passphrase "" \
        --quick-generate-key "Proton Mail Bridge (spaces)" default default never
    fi
    if [ ! -f "$PASSWORD_STORE_DIR/.gpg-id" ]; then
      fpr=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')
      pass init "$fpr"
    fi

    # exec the real Bridge by absolute path: no PATH lookup, no self-recursion.
    exec ${lib.getExe package} "$@"
  '';
}
