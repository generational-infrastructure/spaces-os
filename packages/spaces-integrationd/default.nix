{ inputs, pkgs, ... }:
# spaces-integrationd — the per-user agent-integrations broker
# (docs/agent-integrations-poc-plan.md step 2, unified profile store per
# docs/agent-integrations-skill-migration-plan.md).
#
# A --user systemd service that owns enable/disable + per-profile field
# provisioning over %t/spaces-integrations.sock, SO_PEERCRED-gated to the owning
# uid. The store engine is skill-config (config.toml + host+tpm2-sealed secrets
# blob); secrets are encrypted user-scoped and never leave as plaintext.
let
  skillConfig = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.skill-config;
in
pkgs.buildGoModule {
  pname = "spaces-integrationd";
  version = "0.1.0";
  src = ./.;
  # Pure stdlib: net, encoding/json, os/exec, syscall.
  vendorHash = null;
  doCheck = true;
  # The Go tests drive the REAL skill-config (store engine); systemd-creds and
  # systemctl are stubbed inside the test since they need a TPM / a live manager.
  nativeCheckInputs = [ skillConfig ];
  meta.mainProgram = "spaces-integrationd";
}
