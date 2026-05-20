# Noctalia AI chat plugin.
#
# Base integration layer.  Single import for users who already run
# noctalia-shell.  Provides the chat panel plugin, the pi --mode rpc
# backend, and llama-swap LLM serving.
#
# Each chat session runs its own pi process in a systemd-run --user
# transient service sandbox (ProtectHome=tmpfs + selective binds).
{ inputs, ... }:
_: {
  imports = [
    inputs.self.nixosModules.pi-chat
    inputs.self.nixosModules.llama-swap
  ];

  services.pi-chat = {
    enable = inputs.nixpkgs.lib.mkDefault true;
    noctaliaPlugin = inputs.nixpkgs.lib.mkDefault true;
  };
}
