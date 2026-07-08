"""Local pytest bootstrap: generate the gRPC stubs from the vendored proto.

`nix build` generates bridge_pb2*.py in default.nix's preBuild (grpcio-tools as a
nativeBuildInput), so under the sandbox this is a no-op. For local iteration the
stubs may be absent, so we compile them once from bridge.proto before any test
module imports them, and make sure the package dir is importable.
"""

import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))


def _ensure_stubs():
    stubs = [os.path.join(_HERE, n) for n in ("bridge_pb2.py", "bridge_pb2_grpc.py")]
    if all(os.path.exists(p) for p in stubs):
        return
    subprocess.run(
        [
            sys.executable,
            "-m",
            "grpc_tools.protoc",
            "-I",
            _HERE,
            f"--python_out={_HERE}",
            f"--grpc_python_out={_HERE}",
            "bridge.proto",
        ],
        cwd=_HERE,
        check=True,
    )


_ensure_stubs()
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
