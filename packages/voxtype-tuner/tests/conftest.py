"""Shared test isolation.

Every test runs with ``VOXTYPE_TUNER_DEFAULT_CONFIG`` pointed at a path that
does not exist and ``XDG_CONFIG_HOME`` at an empty tmp dir, so the defaults
loader never reads the host's real ``/etc/xdg/voxtype/config.toml`` or
``~/.config/voxtype/config.toml``. On a machine that runs the NixOS voxtype
module those files exist and would leak host tuning into tests that construct
windows without an explicit defaults object. In the nix-build sandbox they
never exist, so without this pin the two environments would diverge. Tests
that exercise the loader override the variables themselves.
"""

import pathlib

import pytest


@pytest.fixture(autouse=True)
def _isolate_system_defaults(
    monkeypatch: pytest.MonkeyPatch, tmp_path: pathlib.Path
) -> None:
    monkeypatch.setenv(
        "VOXTYPE_TUNER_DEFAULT_CONFIG", str(tmp_path / "absent-system-config.toml")
    )
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "xdg-config"))
    # The take path is derived (and its directory created) whenever the
    # transcribe wiring fires. Keep that out of the real ~/.local/share.
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "xdg-data"))
