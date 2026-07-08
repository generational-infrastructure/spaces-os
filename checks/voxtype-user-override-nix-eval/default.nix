# Cheap nix-eval + wrapper-behaviour contract for the voxtype user-override
# mechanism (modules/nixos/voxtype.nix).
#
# The voxtype-tuner "Apply" action writes ~/.config/voxtype/config.toml and
# restarts the user service. The daemon must then actually run against that
# file. The unit used to pin `-c <store config>` unconditionally, so a user
# override was written and silently IGNORED, while the module comment
# claimed overrides worked. This check guards the fix:
#
#   - ExecStart is the voxtype-daemon wrapper, not a bare `voxtype -c ...`.
#   - the wrapper script (realised and read from the store, cheap: it execs
#     voxtype by name, so its closure is bash + the generated TOML, not the
#     voxtype package) contains both the $XDG_CONFIG_HOME user probe and the
#     store-config fallback. The probe is load-bearing: `voxtype -c
#     <missing>` silently runs on built-in defaults (src/config/load.rs),
#     which would re-enable the hotkey grab and OSD the module disables.
#   - functionally: a stub `voxtype` on PATH captures argv. With no user
#     file the wrapper passes the store config. With one present (plain
#     $HOME and $XDG_CONFIG_HOME flavours) it passes the user file.
#   - `voxtype` stays resolvable by name in the unit's PATH.
#   - cuda variants keep the LD_LIBRARY_PATH env wiring, which the wrapper
#     indirection must not eat (x86_64-only and eval-only, no CUDA builds.
#     Build coverage of the variant itself lives in voxtype-parakeet-cuda).
#
# Builds only the wrapper + generated-config derivations. ~1s, no VM.
{ pkgs, inputs, ... }:
let
  inherit (pkgs) lib;

  mkSystem =
    name: extraModules:
    inputs.self.lib.mkEvalSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        inputs.self.nixosModules.spaces
        { networking.hostName = name; }
      ]
      ++ extraModules;
    };

  defaultSystem = mkSystem "voxtype-override" [ ];
  unit = system: system.config.systemd.user.services.voxtype;

  # Carries string context, so realising the check builds the wrapper and
  # lets the script below read it from the store.
  execStart = (unit defaultSystem).serviceConfig.ExecStart;
  configToml = defaultSystem.config.environment.etc."xdg/voxtype/config.toml".source;

  # The wrapper execs `voxtype` by name. The unit's PATH must provide it.
  # Touching .name is eval-only. It does not build the package.
  unitPathHasVoxtype = lib.any (p: lib.hasInfix "voxtype" p.name) (unit defaultSystem).path;

  # CUDA on aarch64 is fragile and unused (same scoping rationale as the
  # voxtype-parakeet-cuda check), so only exercise the cuda eval on x86_64.
  includeCuda = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
  cudaAttrs = lib.optionalAttrs includeCuda (
    let
      cudaSystem = mkSystem "voxtype-override-cuda" [
        {
          nixpkgs.config.allowUnfree = true;
          spaces.voxtype = {
            engine = "parakeet";
            variant = "parakeet-cuda";
          };
        }
      ];
    in
    {
      # Context discarded: we assert on the path STRINGS only, never
      # realising the CUDA closure.
      cudaExecStart = builtins.unsafeDiscardStringContext (unit cudaSystem).serviceConfig.ExecStart;
      cudaLdLibraryPath = builtins.unsafeDiscardStringContext (
        (unit cudaSystem).environment.LD_LIBRARY_PATH or ""
      );
    }
  );
in
pkgs.runCommand "voxtype-user-override-nix-eval-test"
  (
    {
      inherit execStart configToml;
      unitPathHasVoxtype = if unitPathHasVoxtype then "true" else "false";
      checkCuda = if includeCuda then "true" else "false";
    }
    // cudaAttrs
  )
  ''
    set -euo pipefail

    [[ "$execStart" == /nix/store/*/bin/voxtype-daemon ]] \
      || { echo "FAIL: ExecStart = $execStart (expected the voxtype-daemon wrapper)"; exit 1; }

    grep -F 'XDG_CONFIG_HOME:-$HOME/.config}/voxtype/config.toml' "$execStart" > /dev/null \
      || { echo "FAIL: wrapper lost the XDG user-config probe"; exit 1; }
    grep -F "$configToml" "$execStart" > /dev/null \
      || { echo "FAIL: wrapper lost the store-config fallback ($configToml)"; exit 1; }

    [ "$unitPathHasVoxtype" = "true" ] \
      || { echo "FAIL: voxtype package missing from the unit's path, the wrapper execs it by name"; exit 1; }

    # functional: which config does the wrapper hand to voxtype?
    mkdir -p stub
    cat > stub/voxtype <<'EOF'
    #!/bin/sh
    printf '%s\n' "$@" > "$ARGV_OUT"
    EOF
    chmod +x stub/voxtype
    export PATH="$PWD/stub:$PATH"

    # no user override → the Nix-generated config
    mkdir -p home-plain
    ARGV_OUT="$PWD/argv-default" HOME="$PWD/home-plain" "$execStart"
    printf '%s\n' -c "$configToml" daemon > expected-default
    diff -u expected-default argv-default \
      || { echo "FAIL: without an override the wrapper must pass the store config"; exit 1; }

    # ~/.config/voxtype/config.toml present → the user file wins
    mkdir -p home-tuned/.config/voxtype
    echo '# tuned by voxtype-tuner' > home-tuned/.config/voxtype/config.toml
    ARGV_OUT="$PWD/argv-home" HOME="$PWD/home-tuned" "$execStart"
    printf '%s\n' -c "$PWD/home-tuned/.config/voxtype/config.toml" daemon > expected-home
    diff -u expected-home argv-home \
      || { echo "FAIL: override in ~/.config was ignored, the bug this check guards"; exit 1; }

    # $XDG_CONFIG_HOME relocation is honored too
    mkdir -p xdg-conf/voxtype
    echo '# tuned by voxtype-tuner' > xdg-conf/voxtype/config.toml
    ARGV_OUT="$PWD/argv-xdg" HOME="$PWD/home-plain" XDG_CONFIG_HOME="$PWD/xdg-conf" "$execStart"
    printf '%s\n' -c "$PWD/xdg-conf/voxtype/config.toml" daemon > expected-xdg
    diff -u expected-xdg argv-xdg \
      || { echo "FAIL: override under \$XDG_CONFIG_HOME was ignored"; exit 1; }

    # cuda variants: env wiring survives the wrapper indirection
    if [ "$checkCuda" = "true" ]; then
      [[ "$cudaExecStart" == /nix/store/*/bin/voxtype-daemon ]] \
        || { echo "FAIL: cuda ExecStart = $cudaExecStart (expected the wrapper)"; exit 1; }
      [[ "$cudaLdLibraryPath" == *cudart* && "$cudaLdLibraryPath" == *cublas* ]] \
        || { echo "FAIL: cuda LD_LIBRARY_PATH = '$cudaLdLibraryPath' (cudart/cublas wiring lost)"; exit 1; }
    fi

    echo "PASS: user override honored, store config the fallback" >&2
    touch "$out"
  ''
