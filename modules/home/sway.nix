{ lib, ... }:
let
  kb = import ./keybinds.nix { inherit lib; };

  modifier = kb.modifierDefault;

  # Neutral chords ("Mod+Shift+H") -> sway tokens: resolve the modifier,
  # lowercase single letters to xkb keysyms ("A" -> "a"), rename the few
  # named keys that differ. Digits and names like Return pass through.
  keyRenames = {
    Slash = "slash";
  };
  isSingleLetter = tok: builtins.match "[A-Za-z]" tok != null;
  resolveToken =
    tok:
    if tok == "Mod" then
      modifier
    else
      keyRenames.${tok} or (if isSingleLetter tok then lib.toLower tok else tok);
  resolveChord = chord: lib.concatMapStringsSep "+" resolveToken (lib.splitString "+" chord);

  fixedActions = {
    focus-left = "focus left";
    focus-down = "focus down";
    focus-up = "focus up";
    focus-right = "focus right";
    move-left = "move left";
    move-down = "move down";
    move-up = "move up";
    move-right = "move right";
    close-window = "kill";
    fullscreen = "fullscreen toggle";
    toggle-float = "floating toggle";
    reload-config = "reload";
    quit = "exit";
  };
  actionToSway =
    action:
    fixedActions.${action} or (
      if lib.hasPrefix "workspace-switch-" action then
        "workspace number ${lib.removePrefix "workspace-switch-" action}"
      else if lib.hasPrefix "workspace-move-" action then
        "move container to workspace number ${lib.removePrefix "workspace-move-" action}"
      else
        throw "keybinds.nix: no sway mapping for action '${action}'"
    );

  spawnToSway = spawn: "exec ${if lib.isList spawn then lib.concatStringsSep " " spawn else spawn}";

  bindToSway =
    bind:
    if (bind.spawn or null) != null then
      spawnToSway bind.spawn
    else if (bind.command or null) != null then
      bind.command
    else
      actionToSway bind.action;

  rendered = lib.mapAttrs' (
    chord: bind: lib.nameValuePair (resolveChord chord) (bindToSway bind)
  ) kb.defaults;
in
{
  # Guard distro's own data: exactly one of spawn/action/command per bind.
  assertions = lib.mapAttrsToList (chord: bind: {
    assertion =
      lib.count (x: x != null) [
        (bind.spawn or null)
        (bind.action or null)
        (bind.command or null)
      ] == 1;
    message = "keybinds.nix defaults.\"${chord}\": set exactly one of spawn/action/command.";
  }) kb.defaults;

  wayland.windowManager.sway = {
    enable = true;
    config = {
      # mkDefault so an importer overrides through the native option:
      # config.keybindings."Mod4+Return" = "exec ghostty" wins for that
      # chord while every other default survives; config.modifier is the
      # single knob, sourced from keybinds.nix.
      modifier = lib.mkDefault modifier;
      keybindings = lib.mapAttrs (_chord: lib.mkDefault) rendered;
      # No bar by default: home-manager ships a populated i3status bar
      # otherwise, and bars stay the importer's business. Set at normal
      # priority; importers re-add one with config.bars = lib.mkForce [ ].
      bars = [ ];
    };
  };
}
