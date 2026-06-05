{ pkgs, ... }:
pkgs.buildGoModule {
  pname = "spaces-apps";
  version = "0.1.0";
  src = ./.;
  # Pure stdlib: net, encoding/json, os, flag, fmt.
  vendorHash = null;
  meta.mainProgram = "spaces-apps";

  # Ship bash completion at the standard XDG location; bash-completion
  # auto-discovers it. The completion script also lives in /etc via
  # the apps NixOS module so user shells without bash-completion's
  # full auto-discovery still pick it up.
  postInstall = ''
    install -Dm0644 ${./completion.bash} \
      $out/share/bash-completion/completions/spaces-apps
  '';
}
