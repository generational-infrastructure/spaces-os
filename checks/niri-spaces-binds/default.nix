# Cheap nix-eval contract for the spaces keybind model and its niri
# rendering.
#
# Every spaces shortcut must spawn a controlled spaces-* wrapper (see
# modules/nixos/spaces-commands.nix), never a raw command, so a failed
# shortcut posts a desktop notification. The wrapper names are read back
# from the evaluated system so this check and niri.nix can't drift.
#
# The standalone-chat migration once silently repurposed Mod+Shift+N
# (noctalia bar reload) to pi-chat; the regression guard pins that the
# bar-reload chord is not the chat-reload wrapper.
#
# The binds now live in modules/keybinds.nix (shared with the sway
# renderer), so two model-level pins are added:
#   1. every model niri bind renders as its exact expected kdl line, so
#      the niri.nix sed renderer can't drift from the model;
#   2. every model bind's chord appears in docs/keybindings.md, so
#      adding a bind without a docs row fails this check instead of
#      silently shipping undocumented.
{ pkgs, inputs, ... }:
let
  lib = inputs.nixpkgs.lib;
  kb = import ../../modules/keybinds.nix { inherit lib; };

  # Chord spellings: niri collapses SMod (spaces command modifier) to
  # its own Mod (mirrors niriChord in modules/nixos/niri.nix); the docs
  # additionally write `/` for the Slash keysym.
  niriChord =
    chord:
    lib.concatMapStringsSep "+" (tok: if tok == "SMod" then "Mod" else tok) (
      lib.splitString "+" chord
    );
  docChord = chord: lib.replaceStrings [ "Slash" ] [ "/" ] (niriChord chord);

  # Exact kdl lines niri.nix must have injected, one per model niri bind.
  expectedKdlLines = pkgs.writeText "expected-niri-bind-lines" (
    lib.concatMapStringsSep "\n" (
      bind: "    ${niriChord bind.chord} hotkey-overlay-title=\"${bind.title}\" { spawn \"${bind.spawn}\"; }"
    ) kb.niriSpawnBinds
  );

  # Every model bind (niri and sway alike) must be documented.
  expectedDocChords = pkgs.writeText "expected-doc-chords" (
    lib.concatStringsSep "\n" (lib.unique (map docChord (lib.attrNames kb.binds)))
  );

  system = inputs.self.lib.mkEvalSystem {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = [ inputs.self.nixosModules.niri ];
  };
  niriConfig = system.config.environment.etc."niri/config.kdl".source;
  cmds = system.config.services.spaces.commands;
in
pkgs.runCommand "niri-spaces-binds-test"
  {
    inherit niriConfig;
    chatToggle = cmds.chat-toggle.name;
    chatQuickLaunch = cmds.chat-quick-launch.name;
    voiceRecordToggle = cmds.voice-record-toggle.name;
    barReload = cmds.bar-reload.name;
    chatReload = cmds.chat-reload.name;
    screenLock = cmds.screen-lock.name;
    inherit expectedKdlLines expectedDocChords;
    docs = ../../docs/keybindings.md;
  }
  ''
    set -euo pipefail
    fail() { echo "FAIL: $*" >&2; exit 1; }

    # Each spaces chord spawns its dedicated notifying wrapper.
    grep -qE "Mod\+A .*spawn \"$chatToggle\"" "$niriConfig" \
      || fail "Mod+A must spawn $chatToggle"
    grep -qE "Mod\+Slash .*spawn \"$chatQuickLaunch\"" "$niriConfig" \
      || fail "Mod+Slash must spawn $chatQuickLaunch (quick-launch agent bar)"
    grep -qE "Mod\+S .*spawn \"$voiceRecordToggle\"" "$niriConfig" \
      || fail "Mod+S must spawn $voiceRecordToggle"
    grep -qE "Mod\+Shift\+N .*spawn \"$barReload\"" "$niriConfig" \
      || fail "Mod+Shift+N must spawn $barReload (noctalia bar reload)"
    grep -qE "Mod\+Shift\+A .*spawn \"$chatReload\"" "$niriConfig" \
      || fail "Mod+Shift+A must spawn $chatReload (pi-chat reload)"
    grep -qE "Mod\+L .*spawn \"$screenLock\"" "$niriConfig" \
      || fail "Mod+L must spawn $screenLock"
    grep -qE "Ctrl\+Alt\+L .*spawn \"$screenLock\"" "$niriConfig" \
      || fail "Ctrl+Alt+L must spawn $screenLock"

    # Guard the chords spaces rebinds away from their old raw commands:
    # these tokens must now only appear inside the wrapper names, never
    # as a bare spawn target on a spaces chord. (Upstream's own
    # Super+Alt+L swaylock bind is intentionally left untouched.)
    for chord in 'Mod\+A' 'Mod\+Slash' 'Mod\+S' 'Mod\+Shift\+N' 'Mod\+Shift\+A'; do
      if grep -qE "$chord .*\{ spawn \"(pi-chat-toggle|voxtype|systemctl|sh)\"" "$niriConfig"; then
        fail "$chord spawns a raw command instead of a spaces-* wrapper"
      fi
    done
    # Regression guard: the noctalia bar chord must not be the pi-chat one.
    if grep -qE "Mod\+Shift\+N .*spawn \"$chatReload\"" "$niriConfig"; then
      fail "Mod+Shift+N is bound to the pi-chat reload — noctalia bar reload was clobbered"
    fi

    # Renderer pin: each model niri bind is present as its exact kdl line.
    while IFS= read -r line; do
      grep -qxF "$line" "$niriConfig" \
        || fail "model bind not rendered into config.kdl: $line"
    done < "$expectedKdlLines"

    # Docs pin: every model bind's chord is documented in
    # docs/keybindings.md (as \`chord\`). Adding a model bind without a
    # docs row fails here.
    while IFS= read -r chord; do
      grep -qF "\`$chord\`" "$docs" \
        || fail "model bind $chord missing from docs/keybindings.md"
    done < "$expectedDocChords"

    touch "$out"
  ''
