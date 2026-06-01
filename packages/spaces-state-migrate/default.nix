{ pkgs, ... }:
pkgs.python3Packages.buildPythonApplication {
  pname = "spaces-state-migrate";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ pkgs.python3Packages.hatchling ];
  doCheck = true;
  nativeCheckInputs = [ pkgs.python3Packages.pytestCheckHook ];
  pytestFlags = [ "test_migrate.py" ];
  meta = {
    description = "One-shot user-state migration for the 2026-05 'distro' → 'spaces' rename";
    mainProgram = "spaces-state-migrate";
  };
}
