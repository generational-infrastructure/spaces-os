# Same deal as llama-cpp-cuda: parakeet-cuda only reaches hosts through the
# voxtype module, which buildbot doesn't cache (nor the check that forces it), so
# CUDA hosts rebuild onnxruntime + voxtype-onnx-cuda. Re-export the exact
# derivation so buildbot caches the whole closure.
#
# x86_64 only: CUDA is unfree and unused on aarch64. Touching meta doesn't change
# the output hash.
{ inputs, pkgs, ... }:
inputs.voxtype.packages.${pkgs.stdenv.hostPlatform.system}.parakeet-cuda.overrideAttrs (old: {
  meta = (old.meta or { }) // {
    platforms = [ "x86_64-linux" ];
  };
})
