# Local dev/test/run environment for packages/voxtype-tuner, entered with
# `nix develop .#voxtype-tuner`. It replaces the old uv venv entirely: no uv, no
# hand-built .venv, no hand-maintained LD_LIBRARY_PATH store-path list.
#
# The package (packages/voxtype-tuner/default.nix) deliberately ships only the
# BASE slint wheel, because the windowed app it builds does not need the
# MCP/testing binary. The headless, MCP-driven dev flow (run.sh, the README
# verify runbook) DOES need it: slint/_native.py loads the separate top-level
# `slint_dev_native` module whenever SLINT_MCP_PORT / SLINT_TEST_SERVER is set,
# and that module ships only in the version-matched `slint-dev` wheel. So this
# shell pairs the package's exact base wheel with slint-dev (same fixed-output,
# autoPatchelf recipe), plus the audio deps and the ruff/mypy/pytest toolchain,
# in one `python.withPackages` env so every import resolves out of the box.
{
  inputs,
  pkgs,
  ...
}:
let
  inherit (pkgs) lib;
  python = pkgs.python313;

  # The packaged app, only to reuse its passthru: the exact base slint wheel and
  # the dlopen'd window libs. Referencing these does not build the app itself
  # (nor its nemotron/voxtype runtime deps), since they are lazy passthru attrs.
  package = pkgs.callPackage ../packages/voxtype-tuner { inherit inputs; };

  # slint's MCP/testing companion: exposes the top-level `slint_dev_native`
  # extension with the system-testing and mcp features compiled in. Same recipe
  # as the base wheel in the package, version-locked to 1.17.0b2 because
  # slint/_native.py refuses a slint-dev whose version != slint. autoPatchelf
  # rewrites its RPATH (0 unsatisfied) so no runtime LD hack is needed; the
  # import check is skipped only to avoid fontconfig init in the sandbox.
  slint-dev = python.pkgs.buildPythonPackage {
    pname = "slint-dev";
    version = "1.17.0b2";
    format = "wheel";
    src = pkgs.fetchPypi {
      pname = "slint_dev";
      version = "1.17.0b2";
      format = "wheel";
      dist = "cp311";
      python = "cp311";
      abi = "abi3";
      platform = "manylinux_2_35_x86_64";
      hash = "sha256-Pa7Jzwzl5XHW7TBTe6RzRjDwJWEnVAfrVBmbxcMDkPE=";
    };
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [
      pkgs.stdenv.cc.cc.lib
      pkgs.expat
      pkgs.glib
      pkgs.zlib
    ];
    # The wheel's dist-info Requires-Dist pins slint==1.17.0b2; we pair it with
    # the base wheel in the env below, so skip the standalone dep validation.
    dontCheckRuntimeDeps = true;
    pythonImportsCheck = [ ];
  };

  # One env with everything an import in the source tree can reach: the base
  # slint wheel (release binary), slint-dev (MCP/headless binary), the audio
  # stack, and the test/type toolchain. withPackages puts them all on the
  # interpreter's own sys.path, so `import slint` / `import slint_dev_native` /
  # `import sounddevice|soundfile|numpy` all resolve with no PYTHONPATH wiring.
  pythonEnv = python.withPackages (ps: [
    package.slint
    slint-dev
    ps.sounddevice
    ps.soundfile
    ps.numpy
    ps.pytest
    ps.mypy
  ]);
in
# The only published slint / slint-dev wheels are manylinux x86_64, so the
# package declares `platforms = [ "x86_64-linux" ]`. Match that here: on any
# other system the shell would try to pull an x86_64 wheel, so hand back a
# trivial shell that fails fast instead of dragging that wheel into a
# cross-system flake check.
if pkgs.stdenv.hostPlatform.system != "x86_64-linux" then
  pkgs.mkShellNoCC {
    shellHook = ''
      echo "voxtype-tuner dev shell is x86_64-linux only (slint ships no other wheel)." >&2
      exit 1
    '';
  }
else
  pkgs.mkShell {
    packages = [
      pythonEnv
      pkgs.ruff
    ];

    # slint's .run() dlopen()s these to open a window under --window (winit), and
    # autoPatchelf can't see a dlopen. Nix-generated from the package's own list,
    # so it is not a hand-maintained store-path list. Harmless for the headless
    # default (extra graphics libs left unused).
    LD_LIBRARY_PATH = lib.makeLibraryPath package.windowLibs;
  }
