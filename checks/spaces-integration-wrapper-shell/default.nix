# Pins the mail-family wrappers' PATH prefix against himalaya's `sh -c`
# credential exec.
#
# himalaya wraps `backend.auth.cmd` in `sh -c <cmd>` (pimalaya process crate,
# src/command.rs), resolving `sh` from PATH — and only once the IMAP
# connection is up, so a config-generation check never exercises it. Inside
# the Landlock-confined integration unit, PATH is the systemd user-manager
# default (coreutils & co — no shell) plus whatever the buildPythonApplication
# wrapper prefixes. If that prefix carries no `sh`, EVERY mail tool call dies
# after connecting with
#   cannot get secret from command: No such file or directory
# which is exactly the failure this check reproduces and forbids.
#
# Method: source the shipped wrapper's PATH surgery (all lines but the final
# exec) starting from an empty PATH — yielding exactly the entries the wrapper
# injects — then run the REAL himalaya from that PATH against a local IMAP
# stub that accepts the connection and rejects LOGIN. Reaching LOGIN proves
# `sh` resolved and the auth.cmd secret made it to the wire.
{ pkgs, inputs, ... }:
let
  inherit (pkgs.stdenv.hostPlatform) system;
  pkgsSelf = inputs.self.packages.${system};
in
pkgs.runCommand "spaces-integration-wrapper-shell"
  {
    meta.platforms = [ "x86_64-linux" ];
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.gnused
      pkgs.coreutils
      pkgs.python3
    ];
    STUB = ./stub.py;
    WRAPPERS = map (p: "${p}/bin/${p.meta.mainProgram}") [
      pkgsSelf.integration-proton
      pkgsSelf.integration-mail
    ];
    # Store-shebanged printf stub (the pure sandbox has no /usr/bin/env).
    AUTHCMD_STUB = pkgs.writeShellScript "authcmd-stub" ''
      printf '%s\n' "secret"
    '';
  }
  ''
    set -euo pipefail

    python3 "$STUB" > port.txt 2> stub.log &
    for _ in $(seq 100); do
      [ -s port.txt ] && break
      sleep 0.1
    done
    PORT=$(cat port.txt)
    echo "stub on port $PORT"

    cat > cfg.toml <<EOF
    [accounts.t]
    email = "t@example.com"
    backend.type = "imap"
    backend.host = "127.0.0.1"
    backend.port = $PORT
    backend.encryption.type = "none"
    backend.login = "t@example.com"
    backend.auth.type = "password"
    backend.auth.cmd = "$AUTHCMD_STUB"
    EOF

    for wrapper in $WRAPPERS; do
      echo "--- $wrapper"
      # The wrapper is PATH surgery + a final exec line; drop the exec and
      # source the rest from an empty PATH to get exactly what it injects.
      sed '$d' "$wrapper" > surgery.sh
      WPATH=$(env -i ${pkgs.bash}/bin/bash -c 'PATH=; . ./surgery.sh; printf %s "$PATH"')
      echo "wrapper PATH: $WPATH"

      : > stub.log
      set +e
      res=$(env -i PATH="$WPATH" himalaya -c cfg.toml envelope list -a t 2>&1)
      set -e
      echo "$res"
      if echo "$res" | grep -q "cannot get secret from command"; then
        echo "FAIL: $wrapper PATH carries no sh — himalaya cannot exec auth.cmd" >&2
        exit 1
      fi
      if ! grep -q "LOGIN-ATTEMPTED" stub.log; then
        echo "FAIL: himalaya never reached LOGIN — secret resolution broke earlier" >&2
        exit 1
      fi
    done
    touch "$out"
  ''
