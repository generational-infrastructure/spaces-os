# Nemotron ONNX model directories, Nix-fetched (git-LFS oids) so any consumer
# stays offline. Shared by the voxtype NixOS module (the daemon's engine) and
# the voxtype-tuner package (its Transcribe button), so the ~2.6 GB fetch is
# defined ONCE here rather than duplicated in both.
#
# Each entry is a directory of five files that MUST live together: encoder.onnx
# loads encoder.onnx.data by relative name. We symlink rather than copy so the
# 2.4 GB .data blob is not duplicated in the store. If onnxruntime is ever seen
# to canonicalise the model path (which would break relative external-data
# resolution through the symlink), switch `ln -s` to `cp`. Hashes are the
# git-LFS oids of the community ONNX export at altunenes/parakeet-rs.
{
  pkgs,
  lib ? pkgs.lib,
}:
{
  "nemotron-3.5-asr-streaming-0.6b" =
    let
      base = "https://huggingface.co/altunenes/parakeet-rs/resolve/main/nemotron-3.5-asr-streaming-0.6b-onnx";
      file =
        name: hash:
        pkgs.fetchurl {
          url = "${base}/${name}";
          inherit hash;
        };
      files = {
        "config.json" = file "config.json" "sha256-sCieGW0RoX48Zhu63+RVyH3kuv/BpeZSpXefXWh8XbA=";
        "tokenizer.model" = file "tokenizer.model" "sha256-zjiV5AgG8Comw6IlFhuW72gtbABUuuMqJF3sQljX0pE=";
        "encoder.onnx" = file "encoder.onnx" "sha256-1Wn754tI+7BOFp0yT10lRjg4zu17X8O/4gmHJEGXm9k=";
        "decoder_joint.onnx" =
          file "decoder_joint.onnx" "sha256-Y0363yTLT3PC+uFws2YR1o20gYZCaILLyPfgLtnyuyk=";
        "encoder.onnx.data" =
          file "encoder.onnx.data" "sha256-dYT4Xfdrya5vvfpTqo2XsHqEJSXRxQHVNtd/2eT1esc=";
      };
    in
    pkgs.runCommand "nemotron-3.5-asr-streaming-0.6b" { } (
      ''
        mkdir -p "$out"
      ''
      + lib.concatStrings (
        lib.mapAttrsToList (name: src: ''
          ln -s ${src} "$out/${name}"
        '') files
      )
    );
}
