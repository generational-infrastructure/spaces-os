# Central library for spaces keyboard-shortcut command wrappers.
#
# `mkSpacesCommand` builds a thin wrapper around a shell command. The
# wrapper runs the command and, if anything in it exits non-zero, posts
# a desktop notification ("failed to <label>") via `notify-send` and
# then propagates the original exit status. Every command bound to a
# spaces keyboard shortcut goes through one of these so a broken
# shortcut surfaces visibly instead of silently doing nothing.
#
# Usage:
#   mkSpacesCommand = import ./spaces-command.nix pkgs;
#   mkSpacesCommand {
#     name  = "spaces-voice-record-toggle";
#     label = "toggle voice recording";   # toast reads "failed to <label>"
#     text  = "voxtype record toggle";     # shell body
#   }
#
# Inside `text` the wrapper exposes `spaces_notify "<message>" [ms]`, a
# helper that posts a normal-urgency info toast under the same "spaces"
# app-name as the failure toast. An optional second argument sets the
# notification's expire time in milliseconds. Use it for
# success/transition feedback (e.g. `spaces_notify "voice recording
# started" 2000`); it is only reached when the command is still
# running, so it never contradicts the failure toast.
#
# `notify-send` and the underlying commands are resolved from PATH (the
# compositor spawns the wrapper with the session PATH, and libnotify is
# installed system-wide on every spaces host); pass `runtimeInputs` for
# anything that must be pinned to a specific package. Tests stub
# `notify-send` first on PATH to assert the toasts.
pkgs:
{
  name,
  label,
  text,
  runtimeInputs ? [ ],
}:
pkgs.writeShellApplication {
  inherit name runtimeInputs;
  text = ''
    spaces_notify() {
      local -a opts=(--app-name=spaces)
      [ -n "''${2:-}" ] && opts+=(--expire-time="$2")
      notify-send "''${opts[@]}" "Spaces" "$1" || true
    }
    spaces_notify_failure() {
      notify-send --app-name=spaces --urgency=critical \
        "Spaces" "failed to ${label}" || true
    }
    trap spaces_notify_failure ERR

    ${text}
  '';
}
