# Spaces fork of upstream `calamares-nixos-extensions`.
#
# We reuse the upstream derivation untouched and only replace files:
#   - config/settings.conf        - drop the `packagechooser` step
#   - config/modules/welcome.conf  - drop internet requirement (offline)
#   - modules/nixos/main.py        - emit a wrapper flake whose inputs are
#                                    locked to pre-staged store paths so
#                                    the install resolves offline.
#
# Files live under ./files/ and are copied over the upstream tree in
# postPatch. A patch-file approach was rejected: the upstream main.py is
# 900+ lines and our rewrite touches most of it, which makes diff-based
# maintenance more fragile than wholesale replacement.
#
# `base` is overridable so the nixpkgs overlay in `installer-iso.nix`
# can shadow `calamares-nixos-extensions` with this fork without hitting
# infinite recursion (passes `prev.calamares-nixos-extensions`).
#
# The runtime spaces-flake path + per-input override map used to be
# substituted into `main.py` at this layer, which made the package
# rebuild whenever any unrelated repo file changed. Both values now
# come from `/etc/calamares-spaces/install.json` (or
# `$CALAMARES_SPACES_CONFIG`), staged by the consumer (installer-iso
# module / VM tests). Keeps this derivation independent of the spaces
# flake source path.
{
  pkgs,
  base ? pkgs.calamares-nixos-extensions,
  ...
}:
let
  inherit (pkgs) lib;
in
base.overrideAttrs (old: {
  pname = "calamares-spaces-extensions";
  postPatch = (old.postPatch or "") + ''
    cp -f ${lib.cleanSource ./files/settings.conf} config/settings.conf
    cp -f ${lib.cleanSource ./files/welcome.conf} config/modules/welcome.conf
    cp -f ${lib.cleanSource ./files/main.py}       modules/nixos/main.py

    # Spaces OS Calamares branding: fork the upstream `nixos` branding dir
    # (reusing its artwork/slideshow) and override branding.desc to rename
    # the product to "Spaces OS". settings.conf selects it via `branding:`.
    cp -r branding/nixos branding/spaces-os
    cp -f ${lib.cleanSource ./files/branding/spaces-os/branding.desc} branding/spaces-os/branding.desc
  '';
})
