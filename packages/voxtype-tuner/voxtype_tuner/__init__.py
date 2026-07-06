"""voxtype-tuner: a headless-capable Slint UI skeleton for tuning voxtype.

The Slint runtime reads SLINT_BACKEND / SLINT_EMIT_DEBUG_INFO once, at
``import slint`` time. Importing this package (which happens before
``voxtype_tuner.app`` runs under ``python -m voxtype_tuner.app``) seeds sensible
defaults so the app is MCP-inspectable even when run.sh has not set them.
"""

import os

# No X/Wayland/GPU is required here. The Slint MCP server still renders
# screenshots under the headless backend. run.sh may override SLINT_BACKEND.
os.environ.setdefault("SLINT_BACKEND", "headless")
# Preserve element ids in the compiled UI so the MCP server can resolve
# MainWindow::<id>. Without this find_elements_by_id returns nothing.
os.environ.setdefault("SLINT_EMIT_DEBUG_INFO", "1")
