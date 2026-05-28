#!/usr/bin/env python3
"""Component test: chat panel palette tracks noctalia's colors.json.

The standalone chat panel used to hard-code noctalia's default dark
scheme, so it ignored the user's actual theme entirely — buttons and
surfaces rendered in colours that had nothing to do with the bar. The
Color singleton MUST instead read noctalia's generated colors.json
(honouring $NOCTALIA_CONFIG_DIR, same as noctalia) and MUST live-update
when that file is rewritten, because a colour edit and a light/dark
switch both rewrite it.

This guards two things:
  1. On startup, Color mirrors the on-disk palette (not the built-in
     fallback), so the panel matches whatever scheme noctalia uses.
  2. After an atomic rewrite (the shape of a real noctalia write /
     light-dark flip), Color picks up the new palette within a beat.

Headless quickshell, offscreen platform. No compositor, no pi, no
LLM. ~3s.
"""

import json
import os
import shutil
import subprocess
import sys
import time

# Distinct from the built-in fallback (#070722 surface / #11112d variant
# / #fff59b primary), so a match can only mean the file was read.
SCHEME_LIGHT = {
    "mPrimary": "#2563eb",
    "mOnPrimary": "#ffffff",
    "mSecondary": "#7c5cff",
    "mOnSecondary": "#ffffff",
    "mTertiary": "#0f9d58",
    "mOnTertiary": "#ffffff",
    "mError": "#d93025",
    "mOnError": "#ffffff",
    "mSurface": "#fafafa",
    "mOnSurface": "#101317",
    "mSurfaceVariant": "#d8dae0",
    "mOnSurfaceVariant": "#454953",
    "mOutline": "#b0b4bc",
    "mShadow": "#000000",
    "mHover": "#2563eb",
    "mOnHover": "#ffffff",
}

# A "switch to dark" rewrite — surfaces/text invert.
SCHEME_DARK = {
    "mPrimary": "#8aadf4",
    "mOnPrimary": "#11131a",
    "mSecondary": "#c6a0f6",
    "mOnSecondary": "#11131a",
    "mTertiary": "#a6da95",
    "mOnTertiary": "#11131a",
    "mError": "#ed8796",
    "mOnError": "#11131a",
    "mSurface": "#11131a",
    "mOnSurface": "#e6e9ef",
    "mSurfaceVariant": "#262a36",
    "mOnSurfaceVariant": "#a5adcb",
    "mOutline": "#3a3f4b",
    "mShadow": "#000000",
    "mHover": "#8aadf4",
    "mOnHover": "#11131a",
}

FALLBACK_SURFACE = "#070722"


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    shell_root = os.path.join(work_dir, "shell")
    os.makedirs(shell_root, exist_ok=True)
    shutil.copy2(
        os.path.join(test_dir, "shell.qml"), os.path.join(shell_root, "shell.qml")
    )
    # Stage the real Commons so the test exercises the actual Color/
    # Style/Settings singletons the panel ships.
    shutil.copytree(
        os.path.join(plugin_dir, "Commons"),
        os.path.join(shell_root, "Commons"),
        dirs_exist_ok=True,
    )
    now = time.time()
    for root, _dirs, files in os.walk(shell_root):
        for f in files:
            try:
                os.utime(os.path.join(root, f), (now, now))
            except OSError:
                pass
    return shell_root


def write_colors(noctalia_dir: str, scheme: dict) -> None:
    """Atomically write colors.json, mirroring noctalia's rename-on-save."""
    path = os.path.join(noctalia_dir, "colors.json")
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(scheme, fh)
    os.replace(tmp, path)


def ipc_call(qs_bin: str, shell_qml: str, env: dict, *args: str) -> str:
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:color", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout.strip()


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    os.makedirs(xdg_runtime, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    # The panel reads noctalia's palette from here (same env var noctalia
    # itself honours), so the test owns a private noctalia config dir.
    noctalia_dir = os.path.join(work_dir, "noctalia")
    os.makedirs(noctalia_dir, exist_ok=True)
    write_colors(noctalia_dir, SCHEME_LIGHT)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = {
        "HOME": work_dir,
        "PATH": os.environ.get("PATH", "/bin:/usr/bin"),
        "XDG_RUNTIME_DIR": xdg_runtime,
        "NOCTALIA_CONFIG_DIR": noctalia_dir,
        "QT_QPA_PLATFORM": "offscreen",
        "QT_PLUGIN_PATH": os.environ.get("QT_PLUGIN_PATH", ""),
        "QML2_IMPORT_PATH": os.environ.get("QML2_IMPORT_PATH", ""),
    }

    qs_stdout = open(os.path.join(work_dir, "qs.stdout.log"), "w")
    qs_stderr = open(os.path.join(work_dir, "qs.stderr.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml],
        env=env,
        stdout=qs_stdout,
        stderr=qs_stderr,
    )

    def dump_logs():
        for label, name in [
            ("qs.stdout", "qs.stdout.log"),
            ("qs.stderr", "qs.stderr.log"),
        ]:
            path = os.path.join(work_dir, name)
            if os.path.isfile(path):
                sys.stderr.write(f"\n== {label} ==\n")
                sys.stderr.write(open(path).read())

    def die(msg):
        dump_logs()
        fail(msg)

    def eq(key: str, hex_: str) -> bool:
        return ipc_call(qs_bin, shell_qml, env, "eq", key, hex_) == "true"

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:color" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
            die("quickshell never bound the test:color IPC target")

        # (1) Startup palette must come from colors.json, not the fallback.
        def loaded_light():
            return eq("surface", SCHEME_LIGHT["mSurface"])

        if not wait_until(loaded_light, timeout_s=5):
            die(
                "Color.mSurface did not load from noctalia colors.json "
                f"(got {ipc_call(qs_bin, shell_qml, env, 'surface')!r}, "
                f"want {SCHEME_LIGHT['mSurface']!r})"
            )
        if eq("surface", FALLBACK_SURFACE):
            die("Color.mSurface stuck on the built-in fallback — file ignored")
        for key, want in (
            ("variant", SCHEME_LIGHT["mSurfaceVariant"]),
            ("primary", SCHEME_LIGHT["mPrimary"]),
            ("onSurface", SCHEME_LIGHT["mOnSurface"]),
            ("outline", SCHEME_LIGHT["mOutline"]),
        ):
            if not eq(key, want):
                die(f"Color {key} did not match colors.json (want {want})")

        # (2) Rewrite the file (light -> dark) and assert it live-updates.
        write_colors(noctalia_dir, SCHEME_DARK)

        def switched_dark():
            return eq("surface", SCHEME_DARK["mSurface"]) and eq(
                "primary", SCHEME_DARK["mPrimary"]
            )

        if not wait_until(switched_dark, timeout_s=8):
            die(
                "Color did not react to the colors.json rewrite "
                f"(surface={ipc_call(qs_bin, shell_qml, env, 'surface')!r}, "
                f"want {SCHEME_DARK['mSurface']!r}) — no live theme reload"
            )

        sys.stderr.write("PASS: panel palette tracks noctalia colors.json\n")
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()
