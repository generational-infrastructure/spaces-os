{ pkgs, ... }:
pkgs.python3Packages.buildPythonApplication {
  pname = "google-cli";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ pkgs.python3Packages.hatchling ];
  dependencies = with pkgs.python3Packages; [
    google-api-python-client
    google-auth
  ];
  doCheck = true;
  nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];
  pytestFlags = [ "test_google_cli.py" ];
  meta.mainProgram = "google-cli";
}
