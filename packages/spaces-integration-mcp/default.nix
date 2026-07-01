# Shared MCP server scaffold imported by every integration server
# (JSON-RPC/NDJSON framing, socket activation, credential/shared-dir helpers).
{ pkgs, ... }:
pkgs.python3Packages.buildPythonPackage {
  pname = "spaces-integration-mcp";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ pkgs.python3Packages.hatchling ];
  doCheck = true;
  nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];
  pytestFlags = [ "test_scaffold.py" ];
  meta.description = "Shared MCP server scaffold for spaces integrations";
}
