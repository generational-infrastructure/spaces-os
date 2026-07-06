#!/usr/bin/env bash
# Launch voxtype-tuner from the flake's dev environment. Default is a headless
# run with the Slint MCP server on (for MCP-driven, display-free work). --window
# opens a real desktop window instead.
# Usage: ./run.sh [--window] [PORT]   (PORT default 9317, ignored with --window)
set -euo pipefail
cd "$(dirname "$0")"

# Parse --window before the nix-develop re-exec and carry the decision across it
# in the environment, so it survives the exec that only forwards PORT.
if [ "${1:-}" = "--window" ]; then
  export VOXTYPE_TUNER_WINDOW=1
  shift
fi

PORT="${1:-${SLINT_MCP_PORT:-9317}}"

# Re-exec inside the flake's dev environment. It already ships the autoPatchelf'd
# slint wheel plus sounddevice/soundfile/numpy with correct RPATHs (no
# LD_LIBRARY_PATH hack) and a python carrying every runtime+test dep, the same
# environment `nix build .#voxtype-tuner` assembles. No uv, no hand-built venv.
if [ -z "${VOXTYPE_TUNER_DEVSHELL:-}" ]; then
  export VOXTYPE_TUNER_DEVSHELL=1
  exec nix develop .#voxtype-tuner -c "$0" "$PORT"
fi

# Run our local source tree so edits are picked up with no install step: the
# devshell supplies the deps, and prepending the package dir makes its local
# voxtype_tuner win over the copy baked into the store env.
export PYTHONPATH="$PWD${PYTHONPATH:+:$PYTHONPATH}"

# SLINT_STYLE=cupertino, which slint reads at compile time (before import).
# shellcheck source=scripts/env.sh disable=SC1091
source scripts/env.sh

if [ "${VOXTYPE_TUNER_WINDOW:-0}" = "1" ]; then
  # Real window: the winit backend must be set explicitly because the package
  # __init__ otherwise defaults SLINT_BACKEND to "headless" (which never opens
  # a window). No MCP server in this mode.
  export SLINT_BACKEND="${SLINT_BACKEND:-winit}"
else
  export SLINT_MCP_PORT="$PORT"
  export SLINT_BACKEND="${SLINT_BACKEND:-headless}" # no X/Wayland/GPU, screenshots still work
fi
export SLINT_EMIT_DEBUG_INFO="${SLINT_EMIT_DEBUG_INFO:-1}" # preserves element ids for MCP

# Same default sample the nix package wraps in: whisper.cpp's public-domain
# jfk.wav, pinned by tag. Resolve its store path (offline after the first fetch,
# no runtime curl) so the dev flow also starts with an instantly transcribable
# take. Best-effort: a fetch failure just skips seeding, and a caller-provided
# VOXTYPE_TUNER_SAMPLE_WAV wins. The store-path lookup is parsed with the
# devshell's python, so it needs no extra tool (no jq).
if [ -z "${VOXTYPE_TUNER_SAMPLE_WAV:-}" ]; then
  sample_url="https://github.com/ggerganov/whisper.cpp/raw/v1.7.4/samples/jfk.wav"
  if sample_wav="$(nix store prefetch-file --json "$sample_url" 2>/dev/null |
    python -c 'import json,sys; print(json.load(sys.stdin)["storePath"])' 2>/dev/null)" &&
    [ -n "$sample_wav" ]; then
    export VOXTYPE_TUNER_SAMPLE_WAV="$sample_wav"
  fi
fi

exec python -m voxtype_tuner.app
