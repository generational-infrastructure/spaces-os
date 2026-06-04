{ config, lib, ... }:
let
  kb = import ./keybinds.nix { inherit lib; };

  cfg = config.wayland.windowManager.sway;
  # "Mod" -> the window-manager modifier (config.modifier, the native sway
  # option). "SMod" -> the spaces command modifier (spaces.commandModifier),
  # which defaults to the WM modifier but may be set independently.
  wmModifier = cfg.config.modifier;
  spacesModifier = config.spaces.commandModifier;

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
      wmModifier
    else if tok == "SMod" then
      spacesModifier
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
  options.spaces.commandModifier = lib.mkOption {
    type = lib.types.str;
    default = wmModifier;
    defaultText = lib.literalExpression "config.wayland.windowManager.sway.config.modifier";
    example = "Mod4";
    description = ''
      Modifier key for the spaces agent shortcuts (AI chat, quick-launch,
      voice-to-text, screen lock, bar reload). Defaults to the window-manager
      modifier (config.modifier), so the agent binds follow it. Override to pin
      them independently -- e.g. set this to "Mod4" (Super) while window
      management moves to "Mod1" (Alt) via config.modifier.
    '';
  };

  config = {
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
        # config.modifier = "Mod1" relocates every "Mod" bind, while
        # spaces.commandModifier governs the "SMod" agent binds.
        modifier = lib.mkDefault kb.modifierDefault;
        keybindings = lib.mapAttrs (_chord: lib.mkDefault) rendered;
        # No bar by default: home-manager ships a populated i3status bar
        # otherwise, and bars stay the importer's business. Set at normal
        # priority; importers re-add one with config.bars = lib.mkForce [ ].
        bars = [ ];
      };
    };
  };
}
