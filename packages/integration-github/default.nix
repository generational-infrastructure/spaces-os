{ pkgs, ... }:
pkgs.python3Packages.buildPythonApplication {
  pname = "integration-github";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ pkgs.python3Packages.hatchling ];
  doCheck = true;
  nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];
  pytestFlags = [ "test_integration_github.py" ];
  meta.mainProgram = "integration-github";
}
