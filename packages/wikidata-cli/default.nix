{ pkgs, ... }:
pkgs.python3Packages.buildPythonApplication {
  pname = "wikidata-cli";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ pkgs.python3Packages.hatchling ];
  doCheck = true;
  nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];
  pytestFlags = [ "test_wikidata_cli.py" ];
  meta.mainProgram = "wikidata-cli";
}
