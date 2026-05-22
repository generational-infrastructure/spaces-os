# Memory extension derivation: copies the .ts source and bakes the
# absolute path to the sediment binary at build time. Mirrors
# opencrow's nix/extension-memory.nix pattern so the .ts can stay a
# single self-contained file with a sentinel.
{
  runCommand,
  sediment,
}:
runCommand "pi-chat-extension-memory"
  {
    src = ./.;
    inherit sediment;
    passthru = { inherit sediment; };
  }
  ''
    mkdir -p $out
    cp $src/index.ts $out/index.ts
    substituteInPlace $out/index.ts \
      --replace-fail '@@SEDIMENT_BIN@@' "$sediment/bin/sediment"
  ''
