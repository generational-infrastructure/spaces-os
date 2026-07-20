# Shared llama-cpp GPU build for the llama-swap module and the llama-cpp-cuda
# package. Keep it in one place: the package only exists to get this into the
# cache, which is useless unless its store path matches what the hosts build.
# Two copies drift, and then every host rebuilds llama-cpp from source.
{
  pkgs,
  cudaSupport,
}:
pkgs.llama-cpp.override {
  inherit cudaSupport;
  vulkanSupport = true;
  blasSupport = true;
  rocmSupport = false;
  metalSupport = false;
}
