# Exists only so buildbot builds the CUDA llama-cpp and pushes it to the cache.
# Otherwise it hides inside the llama-swap module, which buildbot doesn't cache,
# and every NVIDIA host rebuilds it. Same derivation the module builds, so the
# cache hits.
#
# x86_64 only: CUDA is unfree and unused on aarch64. Touching meta doesn't change
# the output hash.
{ pkgs, ... }:
(import ../../lib/llama-cpp-accelerated.nix {
  inherit pkgs;
  cudaSupport = true;
}).overrideAttrs
  (old: {
    meta = (old.meta or { }) // {
      platforms = [ "x86_64-linux" ];
    };
  })
