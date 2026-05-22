# Sediment — semantic memory store used by the pi-chat `memory`
# extension. Single Rust binary; LanceDB for vectors, SQLite for the
# graph/access layer.
#
# Passthru `modelCache` is a /nix/store HF-cache directory pre-populated
# with the embedding model (all-MiniLM-L6-v2) at the exact revision
# sediment pins. Pointing $HF_HOME at it lets sediment skip Candle's
# first-run download entirely — the hf_hub crate's cache lookup hits
# the in-store snapshot before any network call.
#
# Tracks upstream v0.5.x; bump `version` + `hash` + `cargoHash`
# together when refreshing. Model revision + per-file SHA-256s mirror
# the hardcoded constants in sediment's src/embedder.rs — bump them
# together if upstream pins a new revision.
{ pkgs, ... }:
let
  bin = pkgs.rustPlatform.buildRustPackage rec {
    pname = "sediment";
    version = "0.5.1";

    src = pkgs.fetchFromGitHub {
      owner = "rendro";
      repo = "sediment";
      tag = "v${version}";
      hash = "sha256-hINSwWJE9/Nq5QT2Y7vgFlrwz4fGVYhT4f98Eb7CS2c=";
    };

    cargoHash = "sha256-NfXChnMYyNyyT3ocdT65Ic6Iu3Zp0LtuTR/Je8FzqZc=";

    nativeBuildInputs = [ pkgs.protobuf ];

    env = {
      PROTOC = "${pkgs.protobuf}/bin/protoc";
      PROTOC_INCLUDE = "${pkgs.protobuf}/include";
    };

    # Upstream tests require network access for embedding-model downloads.
    doCheck = false;

    meta = {
      description = "Semantic memory for AI agents - local-first, MCP-native";
      homepage = "https://github.com/rendro/sediment";
      license = pkgs.lib.licenses.mit;
      mainProgram = "sediment";
    };
  };

  # ── pre-baked embedding model cache ──────────────────────────────────
  #
  # hf_hub's CacheRepo::get reads refs/<revision> for the commit hash
  # then resolves snapshots/<hash>/<filename>. If that file exists, no
  # download is attempted (see hf-hub 0.4.x src/lib.rs). We materialise
  # exactly that layout from fetchurl results so the binary is fully
  # offline-capable on first run.
  modelRevision = "e4ce9877abf3edfe10b0d82785e83bdcb973e22e";
  modelRepoDir = "models--sentence-transformers--all-MiniLM-L6-v2";
  hfBase = "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/${modelRevision}";

  modelSafetensors = pkgs.fetchurl {
    url = "${hfBase}/model.safetensors";
    hash = "sha256-U6pRFy0ULInZASzOFa5NbMDKaJWJURQ3nKy0+rEo2ds=";
  };
  tokenizerJson = pkgs.fetchurl {
    url = "${hfBase}/tokenizer.json";
    hash = "sha256-vlDDYo8r9bteOn8XsfdGEbJWGjon7qsF5aow9BFXIDc=";
  };
  configJson = pkgs.fetchurl {
    url = "${hfBase}/config.json";
    hash = "sha256-lT+cDUY0hrEKaHHML9WfIjsscBhPSYFefvvKtdiQi0E=";
  };

  modelCache = pkgs.runCommand "sediment-model-all-minilm-l6-v2" { } ''
    snap=$out/hub/${modelRepoDir}/snapshots/${modelRevision}
    refs=$out/hub/${modelRepoDir}/refs
    mkdir -p "$snap" "$refs"
    cp ${modelSafetensors} "$snap/model.safetensors"
    cp ${tokenizerJson}    "$snap/tokenizer.json"
    cp ${configJson}       "$snap/config.json"
    # hf_hub treats the revision string as both the ref name and the
    # commit hash; pointing the ref file at itself is what makes the
    # cache hit succeed for Repo::with_revision(... revision).
    printf '%s' '${modelRevision}' > "$refs/${modelRevision}"
  '';
in
bin.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit modelCache;
  };
})
