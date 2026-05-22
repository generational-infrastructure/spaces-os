# Noctalia bar with AI chat integration.
#
# Builds on noctalia-plugin (pi-chat + llama-swap), adds the noctalia
# desktop shell bar, and pulls in voxtype so the chat panel's voice
# button has a working backend.  Use this to add the AI chat bar to
# any Wayland compositor (GNOME, Sway, Hyprland, …).
{ inputs, ... }:
{ ... }:
{
  imports = [
    inputs.self.nixosModules.noctalia-plugin
    inputs.self.nixosModules.noctalia
    inputs.self.nixosModules.voxtype
  ];
}
