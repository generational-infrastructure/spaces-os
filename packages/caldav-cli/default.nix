{ inputs, pkgs, ... }:
let
  inherit (inputs.self.packages.${pkgs.stdenv.hostPlatform.system}) skill-config;
in
pkgs.writeShellApplication {
  name = "caldav";
  runtimeInputs = [
    pkgs.curl
    skill-config
  ];
  text = builtins.readFile ./caldav.sh;
  meta.mainProgram = "caldav";
}
