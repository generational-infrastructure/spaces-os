# End-to-end proof that integration-proton's GENERATED transports trust a
# Proton-Mail-Bridge-style certificate.
#
# Proton Bridge serves a self-signed certificate whose Basic Constraints say
# CA:TRUE. himalaya's rustls IMAP/SMTP stack hard-rejects such a cert as
# `CaUsedAsEndEntity` unless it is pinned, and never trusts the system store for
# SMTP. integration-proton therefore (a) pins the cert for IMAP via
# `backend.encryption.cert` and (b) routes SMTP through msmtp, which trusts it
# via `tls_trust_file`.
#
# Unlike the old hand-written-config check, this one generates the himalaya TOML
# and msmtprc with the REAL integration code (integration_proton._build_config),
# so the pins are proven to come from the integration, not the test. It then
# stands up STARTTLS IMAP/SMTP stubs presenting a freshly minted CA:TRUE cert and
# asserts:
#   * himalaya completes TLS with the integration's pin (and NO
#     CaUsedAsEndEntity), proving Bridge IMAP works on stable himalaya;
#   * himalaya REJECTS the cert with the pin stripped (control — hazard is real);
#   * msmtp completes STARTTLS via the integration's tls_trust_file;
#   * msmtp REJECTS a cert outside its trust_file (control);
# plus two generated-config asserts: the himalaya config carries
# backend.encryption.cert and the msmtprc carries tls_trust_file.
#
# Seams (see ./run.sh): the cert path rides the module's own
# $SPACES_PROTON_BRIDGE_STATE env (cert minted at <state>/config/protonmail/
# bridge-v3/cert.pem); the bridge password rides the generated `integration-
# proton-authcmd` name shadowed on PATH by a printf stub; ports have NO module
# seam (Bridge always listens on 1143/1025, hardcoded constants), so the stub
# listens on high ports and run.sh seds the single generated port line.
#
# Guards the cert-handling contract against himalaya / msmtp upgrades. ~2s. Each
# nix build gets its own loopback netns, so the fixed ports can't collide.
{ pkgs, inputs, ... }:
let
  inherit (pkgs.stdenv.hostPlatform) system;
  pkgsSelf = inputs.self.packages.${system};
  # integration_proton imports spaces_himalaya_core + spaces_integration_mcp at
  # module load; _build_config needs no grpc (that is the setup helper only).
  py = pkgs.python3.withPackages (_ps: [
    pkgsSelf.spaces-himalaya-core
    pkgsSelf.spaces-integration-mcp
  ]);
  # The REAL shipped module whose config generation this check pins.
  integrationProton = pkgsSelf.integration-proton;
in
pkgs.runCommand "spaces-integration-proton-tls"
  {
    meta.platforms = [ "x86_64-linux" ];
    nativeBuildInputs = [
      py
      pkgs.himalaya
      pkgs.msmtp
      pkgs.openssl
      pkgs.gnugrep
      pkgs.coreutils
    ];
    STUB = ./stub.py;
    GEN = ./gen.py;
    # integration_proton.py itself, on PYTHONPATH beside the deps env above.
    PROTON_SITE = "${integrationProton}/${pkgs.python3.sitePackages}";
    # Printf stub for the `integration-proton-authcmd` the generated configs
    # call (himalaya auth.cmd + msmtp passwordeval). writeShellScript gives it a
    # valid /nix/store bash shebang; the pure sandbox has no /usr/bin/env, so a
    # hand-written `#!/usr/bin/env bash` script would fail to exec ("not found").
    AUTHCMD_STUB = pkgs.writeShellScript "integration-proton-authcmd" ''
      printf '%s\n' "bridge-secret"
    '';
  }
  ''
    set -euo pipefail
    export HOME="$TMPDIR"
    cd "$TMPDIR"
    export PYTHONPATH="$PROTON_SITE"
    bash ${./run.sh}
    touch "$out"
  ''
