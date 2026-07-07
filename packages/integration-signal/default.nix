{ inputs, pkgs, ... }:
let
  inherit (inputs.self.packages.${pkgs.stdenv.hostPlatform.system})
    spaces-integration-mcp
    signal-cli
    ;
in
pkgs.python3Packages.buildPythonApplication {
  pname = "integration-signal";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ pkgs.python3Packages.hatchling ];
  # signal-cli (the packages/signal-cli python package, pname spaces-signal-cli)
  # ships the `spaces_signal` package whose db + jsonrpc read helpers are reused
  # here; spaces-integration-mcp is the shared MCP scaffold.
  dependencies = [
    spaces-integration-mcp
    signal-cli
  ];
  doCheck = true;
  nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];
  pytestFlags = [ "test_integration_signal.py" ];
  meta.mainProgram = "integration-signal";
}
