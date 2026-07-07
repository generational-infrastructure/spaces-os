{ pkgs, ... }:
pkgs.python3Packages.buildPythonApplication {
  pname = "spaces-signal-cli";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ pkgs.python3Packages.hatchling ];
  doCheck = true;
  nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];
  pytestFlags = [
    "test_db.py"
    "test_bridge.py"
  ];
  meta = {
    description = "Signal daemon→messages.db forwarder for the spaces AI agent";
    mainProgram = "spaces-signal-bridge";
  };
}
