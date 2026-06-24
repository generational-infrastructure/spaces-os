# pi-landlock-exec — the per-session Landlock launcher (design §6).
#
# A tiny native binary that sits between `systemd-run --user` and `pi`: it reads
# the landlockconfig policy the supervisor emits, applies the Landlock domain
# (best-effort), then execs the runtime confined. It must be native because
# landlock_restrict_self() has to run in the final pre-exec process, which the
# Bun supervisor cannot do for the child (so sandbox.ts only *emits* policy JSON).
#
# `landlockconfig` is an unpublished, pre-1.0 crate pinned by git revision (kept
# in lockstep with Cargo.toml); its FOD hash lives in cargoLock.outputHashes.
{ pkgs, ... }:
pkgs.rustPlatform.buildRustPackage {
  pname = "pi-landlock-exec";
  version = "0.1.0";

  # Only the crate inputs — keep default.nix itself out of src so doc/nix edits
  # don't churn the build.
  src = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
    ];
  };

  cargoLock = {
    lockFile = ./Cargo.lock;
    # git dependency (no crates.io checksum) → fixed-output hash.
    outputHashes = {
      "landlockconfig-0.1.0" = "sha256-4LOauaC3eTLvERp9E7HIcunzkJ7HHcLkLAmaSbisr/c=";
    };
  };
  meta = {
    description = "Per-session Landlock launcher for pi-sessiond";
    mainProgram = "pi-landlock-exec";
    platforms = pkgs.lib.platforms.linux;
  };
}
