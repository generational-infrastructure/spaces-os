# Shared harness for the headless-quickshell checks (`checks/*` that boot
# an offscreen quickshell against a staged QML tree and drive it from a
# python driver).
#
# Imported per check as `import ../../lib/qmllint.nix pkgs`'s sibling:
#
#   (import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
#     name = "pi-session-thinking";
#     dir = ./.;
#   }
#
# Owns everything every such check used to copy-paste:
#   - runCommand + nativeBuildInputs (python, quickshell, coreutils, bash,
#     qtbase, qtdeclarative, plus any extra qt6 QML modules),
#   - the offscreen Qt env: QT_PLUGIN_PATH (runCommand strips quickshell's
#     wrapper, so the qpa offscreen plugin must be re-exported) and
#     QML2_IMPORT_PATH; when `qtModules` is non-empty their qml trees are
#     appended AND mirrored into NIXPKGS_QT6_QML_IMPORT_PATH — modules like
#     qtwebsockets live outside quickshell's bundled QML path and need the
#     double export,
#   - PYTHONPATH for ./qs_harness.py (the shared python driver plumbing),
#   - the canonical driver invocation:
#       driver.py <quickshell_bin> <test_dir> <plugin_dir> <work_dir> [extraArgs...]
#
# The check's own assertions stay entirely in <dir>/driver.py.
pkgs:
let
  inherit (pkgs) lib;
  # qs_harness.py alone on PYTHONPATH — not the whole lib/ dir, so edits to
  # unrelated lib files don't rebuild every quickshell check.
  harnessPy = pkgs.linkFarm "qs-harness-py" [
    {
      name = "qs_harness.py";
      path = ./qs_harness.py;
    }
  ];
in
{
  mkQuickshellCheck =
    {
      # Check name; the derivation is named "<name>-test" (the existing
      # convention across checks/).
      name,
      # The check directory (shell.qml, driver.py, fakes, fixtures).
      dir,
      # The QML plugin tree under test, staged wholesale by
      # qs_harness.stage_shell unless the driver declares a subset.
      pluginDir ? ../programs/pi-chat,
      # Extra qt6 QML modules (e.g. pkgs.qt6.qtwebsockets) — appended to the
      # import paths, incl. the NIXPKGS_QT6_QML_IMPORT_PATH mirror.
      qtModules ? [ ],
      # Override for drivers needing python packages, e.g.
      # pkgs.python3.withPackages (ps: [ ps.websockets ]).
      python ? pkgs.python3,
      # Extra tools the driver (or the component under test) shells out to.
      extraInputs ? [ ],
      # Extra argv appended after the canonical four.
      extraArgs ? [ ],
      # Extra exported env vars (store-path values keep their context).
      env ? { },
      # meta.platforms, for checks pinned to one arch (real daemon builds).
      platforms ? null,
    }:
    pkgs.runCommand "${name}-test"
      (
        {
          nativeBuildInputs = [
            python
            pkgs.quickshell
            pkgs.coreutils
            pkgs.bash
            pkgs.qt6.qtbase
            pkgs.qt6.qtdeclarative
          ]
          ++ qtModules
          ++ extraInputs;
          testDir = dir;
          inherit pluginDir;
        }
        // lib.optionalAttrs (platforms != null) { meta.platforms = platforms; }
      )
      (
        let
          qtQmlPaths = lib.concatMapStringsSep ":" (m: "${m}/lib/qt-6/qml") qtModules;
        in
        ''
          set -euo pipefail
          work=$TMPDIR/work
          mkdir -p "$work"
          export QT_PLUGIN_PATH=${pkgs.qt6.qtbase}/lib/qt-6/plugins
          export QML2_IMPORT_PATH=${pkgs.quickshell}/lib/qt-6/qml${
            lib.optionalString (qtModules != [ ]) ":${qtQmlPaths}"
          }
          ${lib.optionalString (qtModules != [ ]) ''
            export NIXPKGS_QT6_QML_IMPORT_PATH=${qtQmlPaths}
          ''}
          export PYTHONPATH=${harnessPy}''${PYTHONPATH:+:$PYTHONPATH}
          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") env
          )}
          ${python}/bin/python3 "$testDir/driver.py" \
            ${lib.getExe pkgs.quickshell} \
            "$testDir" \
            "$pluginDir" \
            "$work" \
            ${lib.escapeShellArgs extraArgs}
          touch $out
        ''
      );
}
