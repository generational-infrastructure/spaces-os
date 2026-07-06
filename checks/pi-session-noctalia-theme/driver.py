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
import sys

from qs_harness import Quickshell, qs_env, stage_shell, wait_until

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


def write_colors(noctalia_dir: str, scheme: dict) -> None:
    """Atomically write colors.json, mirroring noctalia's rename-on-save."""
    path = os.path.join(noctalia_dir, "colors.json")
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(scheme, fh)
    os.replace(tmp, path)


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    # The panel reads noctalia's palette from here (same env var noctalia
    # itself honours), so the test owns a private noctalia config dir.
    noctalia_dir = os.path.join(work_dir, "noctalia")
    os.makedirs(noctalia_dir, exist_ok=True)
    write_colors(noctalia_dir, SCHEME_LIGHT)

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = qs_env(work_dir, extra={"NOCTALIA_CONFIG_DIR": noctalia_dir})

    qs = Quickshell(qs_bin, shell_qml, env, work_dir, ipc_target="test:color")
    qs.start()

    ipc = qs.ipc
    die = qs.die

    def eq(key: str, hex_: str) -> bool:
        return ipc("eq", key, hex_) == "true"

    try:
        qs.wait_ipc_ready(timeout_s=20)

        # (1) Startup palette must come from colors.json, not the fallback.
        def loaded_light():
            return eq("surface", SCHEME_LIGHT["mSurface"])

        if not wait_until(loaded_light, timeout_s=5):
            die(
                "Color.mSurface did not load from noctalia colors.json "
                f"(got {ipc('surface')!r}, "
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
                f"(surface={ipc('surface')!r}, "
                f"want {SCHEME_DARK['mSurface']!r}) — no live theme reload"
            )

        # (3) NIcon must bake `color` into the SVG markup it paints.
        # Tabler icons stroke with `currentColor`; a MultiEffect tint is
        # luminance-weighted and collapses a black stroke to black for
        # every colour, so the panel's icons would silently stop tracking
        # the theme (invisible on a dark hover bg).
        if not wait_until(
            lambda: ipc("ready", target="test:icon") == "true",
            timeout_s=5,
        ):
            die("NIcon never produced a recoloured source")

        def icon_baked(hex_: str) -> bool:
            ipc("setColor", hex_, target="test:icon")

            def baked():
                m = ipc("markup", target="test:icon")
                return hex_ in m and "currentColor" not in m

            return wait_until(baked, timeout_s=5)

        for hx in ("#ff00ff", "#00ff00"):
            if not icon_baked(hx):
                m = ipc("markup", target="test:icon")
                die(
                    f"NIcon did not bake {hx} into its SVG (markup={m[:120]!r}) "
                    "— icon recolour is not wired to `color`"
                )

        sys.stderr.write(
            "PASS: panel palette tracks noctalia colors.json; "
            "NIcon bakes theme colour into its SVG\n"
        )
    finally:
        qs.stop()


if __name__ == "__main__":
    main()
