"""Minimal stub of the `libcalamares` Python module Calamares injects.

Provides just enough surface for `main.py`'s pure builder functions
(`render_configuration`, `render_flake`) to import and run. The
side-effecting host-env helpers are stubbed as no-ops; tests that
exercise them would need to wire their own fakes.
"""

from collections.abc import Callable


class _GlobalStorage:
    def __init__(self, data: dict[str, object] | None = None) -> None:
        self._data = dict(data or {})

    def value(self, key: str) -> object:
        return self._data.get(key)

    def insert(self, key: str, value: object) -> None:
        self._data[key] = value

    # Test-only helper.
    def reset(self, data: dict[str, object] | None = None) -> None:
        self._data = dict(data or {})


class _Job:
    def setprogress(self, fraction: float) -> None:
        pass


class _Utils:
    @staticmethod
    def gettext_path() -> str:
        return "/dev/null"

    @staticmethod
    def gettext_languages() -> list[str]:
        return []

    @staticmethod
    def debug(msg: str) -> None:
        pass

    @staticmethod
    def warning(msg: str) -> None:
        pass

    @staticmethod
    def error(msg: str) -> None:
        pass

    @staticmethod
    def host_env_process_output(
        _cmd: list[str] | str,
        _callback: Callable[[str], None] | None = None,
        _stdin: str | None = None,
    ) -> int:
        # Tests that need to observe filesystem writes should monkeypatch this.
        return 0


globalstorage = _GlobalStorage()
job = _Job()
utils = _Utils()
