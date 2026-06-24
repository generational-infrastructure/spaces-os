#!/usr/bin/env python3
"""Spaces Voice Indicator — bar-pulse glow GEOMETRY test.

Instantiates the plugin's BarPulseGeometry.qml against stubbed qs.Commons
Settings/Style singletons and asserts the recording glow tracks every
noctalia bar configuration:

  - all four bar positions (top / bottom / left / right) produce a glow on
    the matching edge with the matching orientation — vertical bars get a
    vertical strip, NOT a top horizontal strip;
  - per-monitor visibility: a screen excluded by Settings.data.bar.monitors
    gets no glow at all;
  - floating + framed insets: the glow lines up with the bar's actual ends
    instead of spanning the whole screen edge.

Headless quickshell, offscreen platform. No Wayland, no compositor. ~3-5s.
"""

import json
import os
import shutil
import subprocess
import sys
import time

SCREEN = "DP-1"
W = 1920
H = 1080


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
    shutil.copytree(
        os.path.join(test_dir, "Commons"),
        os.path.join(shell_root, "Commons"),
        dirs_exist_ok=True,
    )
    # BarPulseGeometry.qml is the unit under test; stage it next to
    # shell.qml so `BarPulseGeometry {}` resolves locally. BarPulse.qml
    # (the PanelWindow/layer-shell wrapper) is deliberately NOT staged —
    # it needs a Wayland compositor; the geometry math lives here.
    shutil.copy2(
        os.path.join(plugin_dir, "BarPulseGeometry.qml"),
        os.path.join(shell_root, "BarPulseGeometry.qml"),
    )
    now = time.time()
    for root, _dirs, files in os.walk(shell_root):
        for f in files:
            try:
                os.utime(os.path.join(root, f), (now, now))
            except OSError:
                pass
    return shell_root


def bar(**overrides) -> dict:
    cfg = {
        "barType": "simple",
        "position": "top",
        "monitors": [],
        "density": "default",
        "marginVertical": 4,
        "marginHorizontal": 4,
        "frameThickness": 8,
        "screenOverrides": [],
    }
    cfg.update(overrides)
    return {"bar": cfg}


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    os.makedirs(xdg_runtime, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    env = {
        "HOME": work_dir,
        "PATH": os.environ.get("PATH", "/bin:/usr/bin"),
        "XDG_RUNTIME_DIR": xdg_runtime,
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

    def ipc(*args: str) -> str:
        cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:bargeom", *args]
        out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
        if out.returncode != 0:
            raise RuntimeError(
                f"qs ipc call {args} failed (exit={out.returncode}):\n"
                f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
            )
        return out.stdout.strip()

    def read_geom(cfg: dict, screen=SCREEN, w=W, h=H) -> dict:
        ipc("configure", json.dumps(cfg))
        ipc("setScreen", screen, str(w), str(h))
        return json.loads(ipc("geom"))

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:bargeom" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
            die("quickshell never bound the test:bargeom IPC target")

        def close(a, b, label):
            if abs(float(a) - float(b)) > 0.5:
                die(f"{label}: expected {b}, got {a}")

        def eq(a, b, label):
            if a != b:
                die(f"{label}: expected {b!r}, got {a!r}")

        def rect(g, x, y, w, h, label):
            close(g["bloomX"], x, f"{label} bloomX")
            close(g["bloomY"], y, f"{label} bloomY")
            close(g["bloomW"], w, f"{label} bloomW")
            close(g["bloomH"], h, f"{label} bloomH")

        # ── Guard: top / bottom horizontal strips (unchanged behaviour) ──
        g = read_geom(bar(position="top"))
        t, d = g["thickness"], g["glowDepth"]
        if t <= 0 or d <= 0:
            die(f"top: bad thickness/glowDepth {t}/{d}")
        eq(g["vertical"], False, "top vertical")
        eq(g["gradientVertical"], True, "top gradientVertical")
        eq(g["innerAtStart"], True, "top innerAtStart")
        eq(g["barShown"], True, "top barShown")
        rect(g, 0, t, W, d, "top")

        g = read_geom(bar(position="bottom"))
        eq(g["vertical"], False, "bottom vertical")
        eq(g["gradientVertical"], True, "bottom gradientVertical")
        eq(g["innerAtStart"], False, "bottom innerAtStart")
        rect(g, 0, H - t - d, W, d, "bottom")

        # ── Regression: a LEFT (vertical) bar — currently broken. The glow
        #    must be a vertical strip on the left edge, NOT a top strip. ──
        g = read_geom(bar(position="left"))
        tv, dv = g["thickness"], g["glowDepth"]  # vertical bars are thicker
        eq(g["vertical"], True, "left vertical")
        eq(g["gradientVertical"], False, "left gradientVertical")
        eq(g["innerAtStart"], True, "left innerAtStart")
        rect(g, tv, 0, dv, H, "left")

        # ── A RIGHT (vertical) bar blooms leftward from the right edge. ──
        g = read_geom(bar(position="right"))
        eq(g["vertical"], True, "right vertical")
        eq(g["gradientVertical"], False, "right gradientVertical")
        eq(g["innerAtStart"], False, "right innerAtStart")
        rect(g, W - tv - dv, 0, dv, H, "right")

        # ── Per-monitor visibility: an excluded screen gets no glow. ──
        g = read_geom(bar(position="top", monitors=["DP-2"]))
        eq(g["barShown"], False, "excluded-monitor barShown")
        g = read_geom(bar(position="top", monitors=["DP-1"]))
        eq(g["barShown"], True, "listed-monitor barShown")
        g = read_geom(bar(position="top", monitors=[]))
        eq(g["barShown"], True, "empty-monitors barShown")

        # ── Floating horizontal bar: glow inset by marginHorizontal along
        #    its length and dropped by marginVertical from the edge. ──
        g = read_geom(
            bar(
                position="top",
                barType="floating",
                marginHorizontal=20,
                marginVertical=10,
            )
        )
        rect(g, 20, 10 + t, W - 40, d, "floating-top")

        # ── Floating vertical bar: long axis inset by marginVertical. ──
        g = read_geom(
            bar(
                position="left",
                barType="floating",
                marginHorizontal=20,
                marginVertical=10,
            )
        )
        rect(g, 20 + tv, 10, dv, H - 20, "floating-left")

        # ── Framed bar has margins too (frameThickness), not just floating.
        #    Horizontal: inset by frameThickness, flush to the screen edge. ──
        g = read_geom(bar(position="top", barType="framed", frameThickness=8))
        rect(g, 8, t, W - 16, d, "framed-top")

        # ── Framed vertical bar: long axis inset by frameThickness. ──
        g = read_geom(bar(position="left", barType="framed", frameThickness=8))
        rect(g, tv, 8, dv, H - 16, "framed-left")

        # ── Per-screen override: DP-1 forced to a left bar while the global
        #    default stays top → that monitor's glow follows the override. ──
        g = read_geom(
            bar(position="top", screenOverrides=[{"name": "DP-1", "position": "left"}])
        )
        eq(g["vertical"], True, "override-left vertical")
        rect(g, tv, 0, dv, H, "override-left")

        # ── A disabled override is ignored → falls back to the global top
        #    bar (enabled:false suppresses customisation, not the bar). ──
        g = read_geom(
            bar(
                position="top",
                screenOverrides=[
                    {"name": "DP-1", "position": "left", "enabled": False}
                ],
            )
        )
        eq(g["vertical"], False, "override-disabled vertical")
        eq(g["barShown"], True, "override-disabled barShown")
        rect(g, 0, t, W, d, "override-disabled")

        sys.stderr.write("PASS: bar-pulse glow geometry tracks every bar config\n")
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()
