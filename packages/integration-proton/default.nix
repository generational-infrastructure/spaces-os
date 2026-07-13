{ inputs, pkgs, ... }:
let
  inherit (inputs.self.packages.${pkgs.stdenv.hostPlatform.system})
    spaces-integration-mcp
    spaces-himalaya-core
    ;
in
pkgs.python3Packages.buildPythonApplication {
  pname = "integration-proton";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ pkgs.python3Packages.hatchling ];
  # grpcio-tools compiles the vendored bridge.proto into bridge_pb2*.py in
  # preBuild (below); the runtime needs grpcio + protobuf for the setup helper's
  # gRPC control channel to Proton Bridge, plus the shared MCP + himalaya cores.
  nativeBuildInputs = [ pkgs.python3Packages.grpcio-tools ];
  dependencies = [
    spaces-integration-mcp
    spaces-himalaya-core
    pkgs.python3Packages.grpcio
    pkgs.python3Packages.protobuf
  ];
  # Generate the gRPC stubs from the vendored proto before hatchling packages
  # them (pyproject only-include lists bridge_pb2*.py). The AGPL/GPL proto is
  # vendored verbatim with its licence header; the generated code stays out of
  # version control and is rebuilt from source here.
  preBuild = ''
    python -m grpc_tools.protoc -I. --python_out=. --grpc_python_out=. bridge.proto
  '';
  # himalaya reads IMAP over Bridge; msmtp is the send detour (himalaya 1.2.0
  # rustls rejects Bridge's CA:TRUE cert, pimalaya/himalaya#633). Mirror mail's
  # PATH prefix so the server (and the msmtp it spawns) resolve both binaries.
  # bash provides the `sh` himalaya's `sh -c`-wrapped auth.cmd needs — the
  # confined unit's PATH has no shell (pinned by
  # checks/spaces-integration-wrapper-shell).
  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (pkgs.lib.makeBinPath [
      pkgs.himalaya
      pkgs.msmtp
      pkgs.bash
    ])
  ];
  doCheck = true;
  nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];
  pytestFlags = [
    "test_integration_proton.py"
    "test_integration_proton_setup.py"
  ];
  meta.mainProgram = "integration-proton";
}
