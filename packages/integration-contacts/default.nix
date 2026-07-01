{ inputs, pkgs, ... }:
let
  inherit (inputs.self.packages.${pkgs.stdenv.hostPlatform.system}) spaces-integration-mcp;
in
pkgs.python3Packages.buildPythonApplication {
  pname = "integration-contacts";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ pkgs.python3Packages.hatchling ];
  dependencies = [ spaces-integration-mcp ];
  doCheck = true;
  nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];
  pytestFlags = [ "test_integration_contacts.py" ];
  meta.mainProgram = "integration-contacts";
}
