# Shared himalaya CLI core (config generation, exec/error mapping, tool bodies)
# reused by every mail-family integration server (integration-mail, and the
# later integration-proton, which injects a Bridge transport + pre-flight probe).
{ pkgs, ... }:
pkgs.python3Packages.buildPythonPackage {
  pname = "spaces-himalaya-core";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ pkgs.python3Packages.hatchling ];
  doCheck = true;
  nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];
  pytestFlags = [ "test_himalaya_core.py" ];
  meta.description = "Shared himalaya CLI core for spaces mail-family integrations";
}
