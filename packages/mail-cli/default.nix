{ inputs, pkgs, ... }:
let
  inherit (inputs.self.packages.${pkgs.stdenv.hostPlatform.system}) skill-config;
in
pkgs.writeShellApplication {
  name = "mail";
  runtimeInputs = [
    pkgs.himalaya
    pkgs.coreutils
    skill-config
  ];
  text = builtins.readFile ./mail.sh;
  meta.mainProgram = "mail";
}
