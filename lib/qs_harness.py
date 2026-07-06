"""Shared plumbing for the headless-quickshell checks.

Every checks/* driver that boots quickshell against a staged QML tree used
to re-implement the same helpers: free-port pick, port/predicate waits,
shell staging (copy the plugin files + the check's shell.qml into a
writable dir and refresh mtimes), the offscreen Qt env, the qs spawn with
log capture, and the `qs ipc` call/ready dance. This module owns all of
that; a driver keeps only its scenario logic.

Made importable by lib/quickshell-check.nix, which puts this file (alone)
on PYTHONPATH and invokes every driver with the canonical argv:

    driver.py <quickshell_bin> <test_dir> <plugin_dir> <work_dir> [extra...]

Staging model (`stage_shell`): the WHOLE plugin tree is copied into
<work_dir>/shell (or a declared subset via `plugin_files`, for checks that
intentionally isolate one component), then the check's own QML assets
(*.qml, *.js, qmldir — recursively) are overlaid on top, so a test-local
shell.qml or Commons/ always wins. Adding a new .js file to the plugin
therefore never touches any driver again.
"""

import os
import shutil
import socket
import subprocess
import sys
import time

#: File names staged by the test-dir overlay: QML sources plus the qmldir
#: module manifests. Python drivers, fixtures and default.nix stay out of
#: the shell tree.
_QML_ASSET_EXTS = (".qml", ".js", ".mjs")


def fail(msg: str) -> None:
    """Print FAIL: <msg> on stderr and exit 1 (the check's only failure path)."""
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def free_port() -> int:
    """Pick a currently-free loopback TCP port (bind(0) then close)."""
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2) -> bool:
    """Poll `predicate` until truthy or `timeout_s` elapses."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def wait_for_port(port: int, *, timeout_s: float = 15, host: str = "127.0.0.1") -> bool:
    """Wait until a TCP connect to (host, port) succeeds."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.1)
    return False


def wait_for_path(path: str, *, timeout_s: float = 15) -> bool:
    """Wait until `path` exists (unix sockets, ready files)."""
    return wait_until(lambda: os.path.exists(path), timeout_s=timeout_s, interval_s=0.1)


def touch_tree(root: str) -> None:
    """Refresh every file mtime under `root` to now.

    Staged files come from the nix store with epoch mtimes; quickshell's
    QML cache logic misbehaves on those, so every driver touches the tree
    after staging.
    """
    now = time.time()
    for r, _dirs, files in os.walk(root):
        for f in files:
            try:
                os.utime(os.path.join(r, f), (now, now))
            except OSError:
                pass


def _is_qml_asset(name: str) -> bool:
    return name == "qmldir" or name.endswith(_QML_ASSET_EXTS)


def _subtree_has_qml_assets(src: str) -> bool:
    for _r, _dirs, files in os.walk(src):
        if any(_is_qml_asset(f) for f in files):
            return True
    return False


def _overlay_qml_assets(src: str, dst: str) -> None:
    """Copy the QML assets of `src` into `dst` (recursing into dirs that hold
    any), replacing read-only files already staged from the store."""
    os.makedirs(dst, exist_ok=True)
    for name in sorted(os.listdir(src)):
        s = os.path.join(src, name)
        d = os.path.join(dst, name)
        if os.path.isdir(s):
            # skip asset-less dirs entirely (fixtures/, __pycache__/, ...)
            if _subtree_has_qml_assets(s):
                _overlay_qml_assets(s, d)
        elif _is_qml_asset(name):
            if os.path.exists(d):
                os.chmod(d, 0o644)
            shutil.copy2(s, d)
            os.chmod(d, 0o644)


def stage_shell(
    test_dir: str,
    plugin_dir: str,
    work_dir: str,
    *,
    plugin_files=None,
    overlay_dirs=None,
) -> str:
    """Stage <work_dir>/shell and return its path.

    Copies the whole `plugin_dir` tree (or just `plugin_files`, a list of
    file/dir names relative to it, for checks that intentionally isolate a
    component), then overlays the QML assets of each dir in `overlay_dirs`
    (default: the check dir itself) so test-local files win. Everything is
    made writable and mtime-touched.
    """
    root = os.path.join(work_dir, "shell")
    os.makedirs(root, exist_ok=True)
    if plugin_files is None:
        shutil.copytree(plugin_dir, root, dirs_exist_ok=True)
    else:
        for name in plugin_files:
            src = os.path.join(plugin_dir, name)
            if os.path.isdir(src):
                shutil.copytree(src, os.path.join(root, name), dirs_exist_ok=True)
            else:
                shutil.copy2(src, os.path.join(root, name))
    # store copies are read-only; the overlay (and any scenario writes) need
    # +w — including the root itself, whose mode copytree copied from the store
    os.chmod(root, 0o755)
    for r, dirs, files in os.walk(root):
        for name in dirs:
            os.chmod(os.path.join(r, name), 0o755)
        for name in files:
            os.chmod(os.path.join(r, name), 0o644)
    for od in overlay_dirs if overlay_dirs is not None else (test_dir,):
        _overlay_qml_assets(od, root)
    touch_tree(root)
    return root


def spawn(cmd, work_dir: str, log_name: str, env=None) -> subprocess.Popen:
    """Spawn a helper process (fake daemon, mock LLM, ...) with its stdout+
    stderr captured to <work_dir>/<log_name>."""
    log = open(os.path.join(work_dir, log_name), "w")
    return subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT)


def reap(*procs, timeout_s: float = 5) -> None:
    """terminate → wait(timeout) → kill each given process (None entries ok)."""
    live = [p for p in procs if p is not None]
    for p in live:
        p.terminate()
    for p in live:
        try:
            p.wait(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            p.kill()


def qs_env(work_dir: str, extra=None) -> dict:
    """The minimal offscreen-quickshell environment.

    HOME/XDG_RUNTIME_DIR live under `work_dir`; the Qt plugin/import paths
    come from the exports set up by lib/quickshell-check.nix.
    """
    xdg = os.path.join(work_dir, "xdg")
    os.makedirs(xdg, exist_ok=True)
    os.chmod(xdg, 0o700)
    env = {
        "HOME": work_dir,
        "PATH": os.environ.get("PATH", "/bin:/usr/bin"),
        "XDG_RUNTIME_DIR": xdg,
        "QT_QPA_PLATFORM": "offscreen",
        "QT_PLUGIN_PATH": os.environ.get("QT_PLUGIN_PATH", ""),
        "QML2_IMPORT_PATH": os.environ.get("QML2_IMPORT_PATH", ""),
        "NIXPKGS_QT6_QML_IMPORT_PATH": os.environ.get(
            "NIXPKGS_QT6_QML_IMPORT_PATH", ""
        ),
    }
    if extra:
        env.update(extra)
    return env


class Quickshell:
    """A headless quickshell instance bound to a staged shell.qml.

    Owns the spawn (logs to qs.stdout.log / qs.stderr.log under work_dir),
    the `qs ipc` call convention against `ipc_target`, the readiness wait,
    and the dump-logs-then-fail path.
    """

    LOG_NAMES = ("qs.stdout.log", "qs.stderr.log")

    def __init__(self, qs_bin, shell_qml, env, work_dir, ipc_target=None):
        self.qs_bin = qs_bin
        self.shell_qml = shell_qml
        self.env = env
        self.work_dir = work_dir
        self.ipc_target = ipc_target
        self.proc = None

    def start(self) -> subprocess.Popen:
        out = open(os.path.join(self.work_dir, self.LOG_NAMES[0]), "w")
        err = open(os.path.join(self.work_dir, self.LOG_NAMES[1]), "w")
        self.proc = subprocess.Popen(
            [self.qs_bin, "-p", self.shell_qml], env=self.env, stdout=out, stderr=err
        )
        return self.proc

    def ipc(self, *args, target=None, timeout: float = 15) -> str:
        """`qs ipc call <target> <args...>` → stripped stdout; raises on rc != 0."""
        t = target or self.ipc_target
        r = subprocess.run(
            [self.qs_bin, "ipc", "-p", self.shell_qml, "call", t, *args],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if r.returncode != 0:
            raise RuntimeError(
                f"qs ipc call {t} {args} failed (exit={r.returncode}):\n"
                f"stdout: {r.stdout!r}\nstderr: {r.stderr!r}"
            )
        return r.stdout.strip()

    def ipc_ready(self, target=None) -> bool:
        """True once `qs ipc show` lists the target (the shell finished loading)."""
        t = target or self.ipc_target
        r = subprocess.run(
            [self.qs_bin, "ipc", "-p", self.shell_qml, "show"],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=5,
        )
        return r.returncode == 0 and t in r.stdout

    def wait_ipc_ready(self, *, timeout_s: float = 20, target=None, extra_logs=()):
        t = target or self.ipc_target
        if not wait_until(lambda: self.ipc_ready(t), timeout_s=timeout_s):
            self.die(f"quickshell never bound the {t} IPC target", extra_logs)

    def dump_logs(self, extra=()) -> None:
        """Dump the qs logs plus any `extra` log names under work_dir to stderr."""
        for name in (*self.LOG_NAMES, *extra):
            path = os.path.join(self.work_dir, name)
            if os.path.isfile(path):
                sys.stderr.write(f"\n== {name} ==\n" + open(path).read())

    def die(self, msg: str, extra_logs=()) -> None:
        self.dump_logs(extra_logs)
        fail(msg)

    def stop(self) -> None:
        reap(self.proc)
