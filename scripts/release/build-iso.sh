#!/usr/bin/env bash
# Build the installer ISO via the flake's
# `iso.<arch>-linux.installer` output. Leaves the build result
# symlink at ./result.
#
# Defaults to x86_64-linux. Override with $ARCH for cross/native
# builds of the aarch64 installer:
#
#   ARCH=aarch64-linux ./scripts/release/build-iso.sh
set -euo pipefail

arch=${ARCH:-x86_64-linux}

nix build ".#iso.${arch}.installer" --print-build-logs
