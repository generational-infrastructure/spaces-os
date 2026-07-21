# Pushes voxtype's CUDA build (onnxruntime + voxtype-onnx-cuda) to the cache so
# hosts fetch it instead of recompiling onnxruntime (~1h).
#
# symlinkJoin, not `parakeet-cuda.overrideAttrs`: a meta-only override is
# hash-preserving, so the drv stays identical to the voxtype *input*'s, and
# buildbot won't push a derivation owned by an input flake. This is a fresh
# spaces-os drv, so buildbot builds and pushes it and its whole closure. Keep it
# a real drv — a bare re-export un-caches the closure again.
{ inputs, pkgs, ... }:
let
  parakeet-cuda = inputs.voxtype.packages.${pkgs.stdenv.hostPlatform.system}.parakeet-cuda;
in
pkgs.symlinkJoin {
  name = "voxtype-parakeet-cuda";
  paths = [ parakeet-cuda ];
  # x86_64 only: CUDA is fragile/unused on aarch64.
  meta = {
    description = "Parakeet CUDA (ONNX) voxtype build — cache-population wrapper";
    mainProgram = "voxtype";
    platforms = [ "x86_64-linux" ];
  };
}
