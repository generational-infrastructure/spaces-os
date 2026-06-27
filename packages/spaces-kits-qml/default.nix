{ pkgs, ... }:
# spaces-kits-qml: the native QML port of the spaces-kits UI kits (the Files
# browser and the Arlo "Space" home), launchable as a standalone Quickshell
# app. The web kit lives at packages/spaces-kits; this is the QtQuick surface
# that renders in the Spaces OS desktop with the real Inter / DM Mono faces.
#
# `quickshell -p <folder>` loads <folder>/shell.qml; the `qs.Commons` /
# `qs.Components` imports resolve relative to that config root, so we just
# point quickshell at the vendored QML tree under programs/spaces-kits.
let
  src = ../../programs/spaces-kits;

  launcher = pkgs.writeShellApplication {
    name = "spaces-kits";
    runtimeInputs = [ pkgs.quickshell ];
    text = ''
      exec quickshell -p ${src} "$@"
    '';
  };

  desktopItem = pkgs.makeDesktopItem {
    name = "spaces-kits";
    desktopName = "Spaces OS UI kits";
    comment = "Files and Arlo home reference screens (Kin design system)";
    exec = "spaces-kits";
    terminal = false;
    categories = [
      "Graphics"
      "Utility"
    ];
  };
in
pkgs.symlinkJoin {
  name = "spaces-kits-qml";
  paths = [
    launcher
    desktopItem
  ];
}
