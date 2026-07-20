{ pkgs, ... }:
pkgs.python3Packages.buildPythonApplication {
  pname = "spaces-restore";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ pkgs.python3Packages.hatchling ];
  dependencies = [
    pkgs.python3Packages.pynacl
    pkgs.python3Packages.mnemonic
    pkgs.python3Packages.coincurve
    pkgs.python3Packages.websocket-client
    pkgs.python3Packages.bech32
  ];
  doCheck = true;
  nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];
  pytestFlags = [
    "test_crypto.py"
    "test_manifest.py"
    "test_record.py"
    "test_transport.py"
    "test_discovery.py"
    "test_keys.py"
    "test_secp.py"
    "test_nostr.py"
    "test_config.py"
    "test_generate.py"
    "test_nostr_integration.py"
  ];
  meta.mainProgram = "spaces-restore";
}
