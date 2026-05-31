{ pkgs, ... }:
pkgs.buildGoModule {
  pname = "app-coordinator";
  version = "0.1.0";
  src = ./.;
  # Pure stdlib: net, encoding/json, os/exec, syscall, context.
  vendorHash = null;
  meta.mainProgram = "app-coordinator";
}
