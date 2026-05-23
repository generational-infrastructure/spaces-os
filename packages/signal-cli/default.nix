{ pkgs, ... }:
pkgs.python3Packages.buildPythonApplication {
  pname = "distro-signal-cli";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ pkgs.python3Packages.hatchling ];
  doCheck = true;
  nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];
  pytestFlags = [
    "test_db.py"
    "test_bridge.py"
    "test_cli.py"
  ];
  meta = {
    description = "Signal skill for the distro AI agent (CLI + bridge daemon)";
    mainProgram = "signal";
  };
}
