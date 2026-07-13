{ inputs, pkgs, ... }:
let
  inherit (inputs.self.packages.${pkgs.stdenv.hostPlatform.system})
    spaces-integration-mcp
    spaces-himalaya-core
    ;
in
pkgs.python3Packages.buildPythonApplication {
  pname = "integration-mail";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ pkgs.python3Packages.hatchling ];
  dependencies = [
    spaces-integration-mcp
    spaces-himalaya-core
  ];
  # himalaya wraps backend.auth.cmd in `sh -c` (pimalaya process crate) and the
  # confined unit's PATH carries no shell, so bash (providing bin/sh) must ride
  # the wrapper PATH or every tool call dies fetching the secret (pinned by
  # checks/spaces-integration-wrapper-shell).
  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (pkgs.lib.makeBinPath [
      pkgs.himalaya
      pkgs.bash
    ])
  ];
  doCheck = true;
  nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];
  pytestFlags = [ "test_integration_mail.py" ];
  meta.mainProgram = "integration-mail";
}
