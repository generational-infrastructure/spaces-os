# voxtype-tuner

Voice Tuner: a headless-capable Slint desktop tuner for
[voxtype](https://github.com/peteonrails/voxtype) speech-to-text. One
record/play/transcribe take plus a parameter region (engine, model, language,
VAD, max-duration, initial prompt) lets you A/B the same captured audio across
parameter sets. The whole UI is MCP-inspectable so it can be driven and
asserted headlessly.

## Run

```bash
nix run .#voxtype-tuner   # packaged windowed desktop app
```

The nix package is pure and offline: it vendors the base `slint` 1.17.0b2 wheel
(fixed-output, no runtime `uv` and no network), and `autoPatchelfHook` rewrites
the wheel's RPATH so no runtime `LD_LIBRARY_PATH` hack is needed for slint.
Only the windowing libs slint `dlopen()`s and a fontconfig config go through the
wrapper. Build the closure with `nix build .#voxtype-tuner`
(`result/bin/voxtype-tuner`).

That binary is the *windowed* app (winit backend). The headless, MCP-inspectable
flow stays on the dev launcher below. The headless/testing backend lives only
in the `slint[dev]` wheel it pulls, not in the packaged base wheel.

## Default sample

On startup, when no take is recorded yet, it is pre-loaded with a bundled
default sample, so a fresh run is instantly transcribable/playable and you can
A/B the same clip across parameter sets without recording first. Recording
replaces the take's audio as usual. A take that already holds your recording
is never overwritten.

The sample is whisper.cpp's `samples/jfk.wav`, a public-domain ~11s JFK speech
clip (16 kHz mono), MIT-distributed with whisper.cpp. It is **not** committed to
the repo: the nix package fetches it into the store (fixed-output, offline) and
hands its path to the app via `VOXTYPE_TUNER_SAMPLE_WAV`. `run.sh` resolves the
same store path for the dev flow. Unset that variable (bare checkout) and
seeding is simply skipped. Point it at any WAV to use your own default.

```bash
./run.sh [PORT]        # default 9317, headless + MCP server on
./run.sh --window      # open a real desktop window instead
```

`run.sh` re-execs inside `nix develop .#voxtype-tuner`, the flake's dev shell
(`devshells/voxtype-tuner.nix`), and launches with `SLINT_MCP_PORT` set. That
shell already carries the autoPatchelf'd base slint wheel, its version-matched
`slint-dev` companion, sounddevice/soundfile/numpy, and the window libs, so there
is no uv, no venv, and no `LD_LIBRARY_PATH` store-path hack. Setting
`SLINT_MCP_PORT` makes `slint._native` load the `slint_dev_native` binary (the
MCP and headless-capable one from `slint-dev`), so the app renders and serves its
embedded MCP server without an X, Wayland, or GPU display.

`VOXTYPE_BIN` overrides the transcription binary (defaults to `voxtype` on
PATH). Point it at a fake script for deterministic, model-free runs.

## Verify

Everything the dev flow needs comes from the flake, with no uv, no `.venv`, and
no `LD_LIBRARY_PATH` store-path hack. `nix develop .#voxtype-tuner` (the shell in
`devshells/voxtype-tuner.nix`) pairs the packaged base slint wheel with the
matching `slint-dev` MCP wheel and the ruff/mypy/pytest toolchain, so every
import resolves out of the box. Run the suite against the local source tree:

```bash
cd packages/voxtype-tuner
nix develop .#voxtype-tuner --command bash -c '
  # SLINT_STYLE=cupertino, plus the two headless vars. Setting SLINT_MCP_PORT
  # before "import slint" loads the slint-dev binary with the headless backend,
  # which the real-window and lifecycle regressions need (they abort under the
  # lean release binary). shellcheck source=scripts/env.sh
  source scripts/env.sh
  export SLINT_BACKEND=headless SLINT_MCP_PORT=0
  python -m pytest                 # pure helpers plus the headless-backed path
  ruff check --extend-select I .   # I: import ordering (matches treefmt)
  ruff format --check .
'
```

The authoritative test run stays `nix build .#voxtype-tuner`, which runs the same
suite in-sandbox against the base wheel (the headless-only regressions skip
there, since the package ships no `slint-dev`). Strict `mypy` is a merge-gate
check, where `pyproject.toml` resolves `slint` to `Any`, so it is not part of
this local loop.

The pure orchestration logic (`build_params`, the language checklist
serializer, the `TakeRecorder` state machine, the terminal-lifecycle helpers)
is unit-tested without importing `slint`. The slint-integrated path
(engine to model repopulation, transcript marshalling, clean SIGINT/EOF exit) is
exercised end-to-end through subprocess regressions and the embedded MCP
server driven over JSON-RPC.
