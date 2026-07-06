# shellcheck shell=bash
# Sourced helper for the dev flow (run.sh + the README verify runbook). The nix
# dev environment (`nix develop .#voxtype-tuner`) already provides the
# autoPatchelf'd slint wheel plus sounddevice/soundfile/numpy with correct
# RPATHs, so no LD_LIBRARY_PATH hack is needed here. This file only carries the
# one env knob that must be set before `import slint`.

# The repo styleguide (slint-style skill) renders std-widgets in the cupertino
# style. Read at compile time, i.e. before `import slint`, so it must be in the
# environment of every dev launch path (run.sh and the bare fast-relaunch both
# source this file). The nix wrapper sets the same default for the packaged app.
export SLINT_STYLE="${SLINT_STYLE:-cupertino}"
