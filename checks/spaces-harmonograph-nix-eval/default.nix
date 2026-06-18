# Cheap nix-eval contract for the default Spaces session background —
# wl-harmonograph wired as a graphical-session user service
# (modules/nixos/harmonograph.nix), enabled by default through the
# spaces bundle.
#
# What a plain system build does NOT catch but the feature depends on:
#   - the spaces bundle ships the background ON by default (a regression
#     to opt-in would silently leave niri with no wallpaper renderer);
#   - the service points at the REAL wl-harmonograph binary from the
#     pinned flake input (a wrong/bare ExecStart builds fine yet never
#     draws), and starts under graphical-session.target like the bar;
#   - the colour knobs reach wl-harmonograph's HARMONOGRAPH_FG /
#     HARMONOGRAPH_BG env vars — the hook a dark/light theme switch flips
#     (docs/session-theme-switching.md);
#   - services.spaces.background.enable = false drops the unit entirely
#     (users/tests can opt out or swap the renderer);
#   - the VM OCR path (test-support) disables it, so its swaybg
#     "SPACES_TEST_OK" wallpaper wins the background layer instead of
#     racing two layer-shell renderers.
#
# Eval-only: the service's ExecStart carries the wl-harmonograph store
# path, asserted by string-equality at eval time so the runCommand never
# pulls the Rust build into its closure. ~1s, no VM.
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;

  harmonographBin = "${inputs.self.packages.${system}.wl-harmonograph}/bin/wl-harmonograph";

  baseModules = [
    {
      nixpkgs.hostPlatform = system;
      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
      };
      boot.loader.grub.enable = false;
      system.stateVersion = "26.05";
    }
  ];

  mkSystem =
    extra:
    lib.nixosSystem {
      specialArgs = {
        inherit inputs;
        flake = inputs.self;
      };
      modules = baseModules ++ extra;
    };

  # The default Spaces session: bundle imports harmonograph, on by default.
  defaultSystem = mkSystem [
    inputs.self.nixosModules.spaces
    { networking.hostName = "bg-default"; }
  ];

  # Opt-out: the option must drop the whole unit.
  disabledSystem = mkSystem [
    inputs.self.nixosModules.spaces
    {
      networking.hostName = "bg-off";
      services.spaces.background.enable = false;
    }
  ];

  # The VM OCR path: test-support must keep the harmonograph off so its
  # swaybg "SPACES_TEST_OK" wallpaper owns the background layer.
  testSupportSystem = mkSystem [
    inputs.self.nixosModules.spaces
    inputs.self.nixosModules.test-support
    { networking.hostName = "bg-testsupport"; }
  ];

  svcOf = sys: sys.config.systemd.user.services.wl-harmonograph or null;
  defaultSvc = svcOf defaultSystem;
in
assert lib.assertMsg (
  defaultSvc != null
) "spaces bundle must wire the wl-harmonograph background service on by default";
assert lib.assertMsg (
  defaultSvc.serviceConfig.ExecStart == harmonographBin
) "background ExecStart must point at the real wl-harmonograph binary (${harmonographBin})";
assert lib.assertMsg (
  (svcOf disabledSystem) == null
) "services.spaces.background.enable = false must drop the wl-harmonograph unit";
assert lib.assertMsg ((svcOf testSupportSystem) == null)
  "test-support must disable the harmonograph so the OCR swaybg wallpaper wins the background layer";
pkgs.runCommand "spaces-harmonograph-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.jq ];
    # Plain strings / lists only — no derivation context — so this stays
    # a pure eval check and never realises the wl-harmonograph build.
    serviceJson = builtins.toJSON {
      inherit (defaultSvc)
        partOf
        after
        wantedBy
        environment
        ;
    };
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }

    # ── graphical-session wiring (mirrors the noctalia bar) ─────────
    jq -e '.partOf    | index("graphical-session.target")' <<<"$serviceJson" >/dev/null \
      || fail "background must be partOf graphical-session.target"
    jq -e '.after     | index("graphical-session.target")' <<<"$serviceJson" >/dev/null \
      || fail "background must be ordered after graphical-session.target"
    jq -e '.wantedBy  | index("graphical-session.target")' <<<"$serviceJson" >/dev/null \
      || fail "background must be wantedBy graphical-session.target"

    # ── colour knobs reach wl-harmonograph's env (Part-2 theme hook) ─
    jq -e '.environment.HARMONOGRAPH_BG | test("^#[0-9a-fA-F]{6}$")' <<<"$serviceJson" >/dev/null \
      || fail "HARMONOGRAPH_BG must carry a hex background colour"
    jq -e '.environment.HARMONOGRAPH_FG | test("#[0-9a-fA-F]{6}")' <<<"$serviceJson" >/dev/null \
      || fail "HARMONOGRAPH_FG must carry at least one hex foreground colour"

    echo "OK: spaces ships wl-harmonograph on by default; option disables it; test-support keeps it off"
    touch "$out"
  ''
