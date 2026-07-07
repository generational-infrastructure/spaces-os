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
  # here; spaces-integration-mcp is the shared MCP scaffold (its socket-activation
  # accept helper is also reused by the integration-signal-setup binary). qrcode
  # + pillow render the device-link QR PNG in the setup helper.
  dependencies = [
    spaces-integration-mcp
    signal-cli
    pkgs.python3Packages.qrcode
    pkgs.python3Packages.pillow
  ];
  doCheck = true;
  nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];
  pytestFlags = [
    "test_integration_signal.py"
    "test_integration_signal_setup.py"
  ];
  meta.mainProgram = "integration-signal";
}
