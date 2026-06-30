{ pkgs, ... }:
# spaces-integrationd — the per-user agent-integrations broker
# (docs/agent-integrations-poc-plan.md step 2).
#
# A --user systemd service that owns enable/disable + secret provisioning over
# %t/spaces-integrations.sock, SO_PEERCRED-gated to the owning uid. Secrets are
# encrypted user-scoped (host+tpm2) into the user's own credstore and never
# leave it as plaintext.
pkgs.buildGoModule {
  pname = "spaces-integrationd";
  version = "0.1.0";
  src = ./.;
  # Pure stdlib: net, encoding/json, os/exec, syscall.
  vendorHash = null;
  meta.mainProgram = "spaces-integrationd";
}
