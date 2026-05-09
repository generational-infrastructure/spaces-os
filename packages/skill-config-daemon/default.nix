{ pkgs, ... }:
pkgs.buildGoModule {
  pname = "skill-config-daemon";
  version = "0.1.0";
  src = ./.;
  # Pure stdlib: net, encoding/json, sync, context, crypto/rand.
  vendorHash = null;
  meta.mainProgram = "skill-config-daemon";
}
