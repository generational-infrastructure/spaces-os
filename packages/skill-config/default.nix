{ pkgs, ... }:
pkgs.python3Packages.buildPythonApplication {
  pname = "skill-config";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ pkgs.python3Packages.hatchling ];
  dependencies = with pkgs.python3Packages; [
    tomlkit
    pyyaml
  ];
  meta.mainProgram = "skill-config";
}
