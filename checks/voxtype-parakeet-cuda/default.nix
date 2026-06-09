# Build coverage for the Parakeet CUDA (ONNX) voxtype variant.
#
# `spaces.voxtype.variant = "parakeet-cuda"` is the GPU streaming path used
# by CUDA hosts (e.g. nv1), but no spaces-os host or other check selects
# it — the default everywhere is the `vulkan` whisper variant. So without
# this check `nix flake check` / CI would never compile the onnx-cuda
# build, and an upstream voxtype or nixpkgs break in that derivation would
# slip through silently (as the streaming-startup bugs we already hit did).
#
# This forces the parakeet-cuda derivation to compile (it lands in this
# build's input closure) and asserts the wrapped `voxtype` binary is
# present. We do NOT execute it: the CUDA execution provider needs the
# NVIDIA driver (libcuda.so / /dev/nvidia*) which isn't in the build
# sandbox, so a smoke-run would be flaky for no extra coverage.
#
# Heavy + unfree (CUDA): scoped to x86_64-linux via `meta.platforms`, which
# blueprint uses to drop the check on other systems (CUDA on aarch64 is
# fragile and the variant isn't used there).
{ pkgs, inputs, ... }:
let
  voxtypeCuda = inputs.voxtype.packages.${pkgs.stdenv.hostPlatform.system}.parakeet-cuda;
in
pkgs.runCommand "voxtype-parakeet-cuda-builds"
  {
    meta.platforms = [ "x86_64-linux" ];
  }
  ''
    test -x ${voxtypeCuda}/bin/voxtype \
      || { echo "FAIL: parakeet-cuda build produced no voxtype binary" >&2; exit 1; }
    touch "$out"
  ''
