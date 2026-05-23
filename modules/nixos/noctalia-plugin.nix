# Noctalia AI chat plugin.
#
# Base integration layer.  Single import for users who already run
# noctalia-shell.  Provides the chat panel plugin, the pi --mode rpc
# backend, and llama-swap LLM serving.
#
# Each chat session runs its own pi process in a systemd-run --user
# transient service sandbox (ProtectHome=tmpfs + selective binds).
#
# Bundled skill backends (e.g. signal-cli) are imported here too, but
# their *units* stay condition-gated so an unconfigured fresh system
# pays nothing at runtime until the user actually links an account.
{ inputs, ... }:
_: {
  imports = [
    inputs.self.nixosModules.pi-chat
    inputs.self.nixosModules.llama-swap
    inputs.self.nixosModules.signal-cli
  ];

  services.pi-chat = {
    enable = inputs.nixpkgs.lib.mkDefault true;
    noctaliaPlugin = inputs.nixpkgs.lib.mkDefault true;
  };
}
