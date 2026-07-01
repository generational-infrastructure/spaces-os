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
  doCheck = true;
  nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];
  pytestFlags = [ "test_skill_config.py" ];
  meta.mainProgram = "skill-config";
}
