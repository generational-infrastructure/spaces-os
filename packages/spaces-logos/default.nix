# Single source of truth for the Spaces OS logo SVGs.
#
# The marks are binary-ish artwork that doesn't belong in the repo, so they
# live in a gist and are pulled in as a fixed-output derivation. The three
# installer consumers (Calamares branding, GRUB theme, plymouth splash)
# reference `${spaces-logos}/<file>` and rasterise them unchanged, so the
# rendered outputs stay byte-for-byte identical to the previously committed
# SVGs (verified: the pinned rev's SVGs match the old committed ones).
#
# This adds a build-time network dependency on gist.kenji.rsvp; offline
# *install* is unaffected since the rendered assets are baked into each
# consumer's package output.
#
# Pin an explicit rev (not a branch ref) for reproducibility. Refresh both
# fields together when the gist changes:
#   nix run nixpkgs#nix-prefetch-git -- \
#     --url <url> --rev <current-HEAD-sha>
{ pkgs, ... }:
pkgs.fetchgit {
  url = "https://gist.kenji.rsvp/kenji/735596d953134ee0a55136b95d5aaba7.git";
  rev = "e7cd790a84979ea626e241071c49c4c0834e2f59";
  hash = "sha256-MjDSjMbcv3ltQ8Z4MSnSIQEpWJ0/hzZHM6YJz+yGHng=";
}
