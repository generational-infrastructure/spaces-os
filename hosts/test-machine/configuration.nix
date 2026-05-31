# Test-machine host configuration.
#
# Pure config — no module imports. Modules come from spaces.nix,
# wired in by default.nix (blueprint) or the test harness.
{ config, pkgs, ... }:

let
  # Tiny secondary model so the chat plugin's dropdown has more than one
  # entry to render. Q2 is more than good enough — we never ask this
  # model to produce anything coherent in tests.
  smollm-gguf = pkgs.fetchurl {
    url = "https://huggingface.co/QuantFactory/SmolLM-135M-GGUF/resolve/main/SmolLM-135M.Q2_K.gguf";
    hash = "sha256-DX46drPNJILNba21xfY2tyE0/yPWgOhz43gJdeSYKh4=";
  };

  llama-server = pkgs.lib.getExe' config.services.llama-swap.llama-server-package "llama-server";
in
{
  networking.hostName = "test-machine";

  boot.loader.systemd-boot.enable = true;
  fileSystems."/" = {
    device = "/dev/vda1";
    fsType = "ext4";
  };

  users.users.test = {
    isNormalUser = true;
    uid = 1000;
    initialPassword = "test";
    extraGroups = [ "wheel" ];
  };

  # Override spaces default user for greetd auto-login.
  services.greetd.settings.default_session.user = "test";

  # test-machine is always run as a QEMU VM (via `nix build .#test-vm`
  # or `checks/test-machine.nix`'s runNixOSTest). Use Alt so the guest
  # doesn't fight the host compositor's Super grab.
  services.spaces.niri.modKey = "Alt";

  # Expose a second model so the chat dropdown has more than one entry.
  # The full list shown by `!models` is discovered at runtime from
  # llama-swap's /v1/models endpoint.
  services.pi-chat.defaultModel = "qwen2.5:0.5b";

  services.llama-swap.settings.models.smollm = {
    cmd = "${llama-server} -m ${smollm-gguf} --port \${PORT} --no-webui";
  };

  # Make qwen2.5:0.5b output deterministic so the chat round-trip test
  # gets the same reply across runs. Pi-chat sends temperature via its
  # provider config; llama-swap fills in via modelExtraArgs.
  services.llama-swap.modelExtraArgs."qwen2.5:0.5b" = "--temp 0 --seed 42";
  system.stateVersion = "25.05";
}
