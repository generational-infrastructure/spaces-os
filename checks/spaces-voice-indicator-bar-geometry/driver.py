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
import sys

from qs_harness import Quickshell, qs_env, stage_shell

SCREEN = "DP-1"
W = 1920
H = 1080


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

    # BarPulseGeometry.qml is the unit under test; stage ONLY it next to
    # shell.qml so `BarPulseGeometry {}` resolves locally. BarPulse.qml
    # (the PanelWindow/layer-shell wrapper) is deliberately NOT staged —
    # it needs a Wayland compositor; the geometry math lives here. The
    # check-local Commons/ (stub qs.Commons Settings/Style singletons)
    # rides in via the default test-dir overlay.
    shell_root = stage_shell(
        test_dir, plugin_dir, work_dir, plugin_files=["BarPulseGeometry.qml"]
    )
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = qs_env(work_dir)

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:bargeom")
    qs.start()

    die = qs.die
    ipc = qs.ipc

    def read_geom(cfg: dict, screen=SCREEN, w=W, h=H) -> dict:
        ipc("configure", json.dumps(cfg))
        ipc("setScreen", screen, str(w), str(h))
        return json.loads(ipc("geom"))

    try:
        qs.wait_ipc_ready(timeout_s=20)

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
        qs.stop()


if __name__ == "__main__":
    main()
