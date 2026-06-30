# OpenRouter for the test-machine — two ways in, one source of truth.
#
# (A) Eval-time mode, gated on $OPENROUTER_API_KEY read at eval (so it
#     needs --impure). Switches pi-chat fully onto the openrouter
#     provider. Used by checks/test-machine.nix (which imports this host
#     config) and by `nix run --impure .#test-vm`.
#
# (B) Runtime key injection for the interactive `nix run .#test-vm` with
#     NO --impure: pure eval can't see the env var, so instead the
#     test-vm launcher (packages/test-vm) forwards $OPENROUTER_API_KEY
#     into the guest through QEMU fw_cfg, and the guest stages it for the
#     supervisor at boot. The key never enters the store. This only
#     affects system.build.vm (via virtualisation.vmVariant), so the
#     headless check — which builds nodes through runNixOSTest, not
#     system.build.vm — is untouched by (B).
#
# Under pure eval with no key at all, both are no-ops and the host stays
# on the local llama-swap backend, reproducibly.
{ lib, pkgs, ... }:

let
  openrouterKey = builtins.getEnv "OPENROUTER_API_KEY";
  useOpenrouter = openrouterKey != "";

  # Small, cheap, fast. The round-trip only needs a non-empty reply,
  # not specific content.
  openrouterModel = "google/gemma-4-26b-a4b-it";

  # QEMU user-mode networking (gateway 10.0.2.2, DNS 10.0.2.3) is the
  # VM's path to api.openrouter.ai. Force DHCP + that resolver so
  # NetworkManager doesn't strand outbound DNS. Shared by both modes.
  internet = {
    networking.useDHCP = lib.mkForce true;
    networking.nameservers = lib.mkForce [ "10.0.2.3" ];
    environment.etc."resolv.conf".text = lib.mkForce "nameserver 10.0.2.3\n";
  };

  # fw_cfg channel for mode (B). The launcher publishes the key under
  # this name; QEMU exposes it to the guest at fwCfgPath.
  fwCfgName = "opt/org.spaces/openrouter-key";
  fwCfgPath = "/sys/firmware/qemu_fw_cfg/by_name/${fwCfgName}/raw";
  # The LoadCredential source the pi-chat / pi-sessiond modules
  # expect the OpenRouter key at.
  secretPath = "/run/spaces-secrets/openrouter-api-key";
in
{
  config = lib.mkMerge [
    # ── (A) eval-time openrouter mode (--impure) ──────────────────────
    (lib.mkIf useOpenrouter (
      lib.mkMerge [
        {
          services.pi-chat = {
            defaultProvider = "openrouter";
            # Win over the host's local-model default (qwen2.5:0.5b).
            defaultModel = lib.mkForce openrouterModel;
            openrouter.enable = true;
            # Throwaway test VM: staging the key through the store is fine
            # here. The module restages it under /run (root:users 0640).
            openrouter.apiKeyFile = pkgs.writeText "openrouter-api-key" openrouterKey;
          };
        }
        internet
      ]
    ))

    # ── (B) runtime key injection for `nix run .#test-vm` ─────────────
    {
      virtualisation.vmVariant = lib.mkMerge [
        {
          # Always carry the OpenRouter capability (proxy extension +
          # LoadCredential + secret file) so a key supplied at launch
          # works. mkDefault lets mode (A) win under --impure. Provider
          # stays "local" by default; OpenRouter's catalog still shows up
          # in the panel picker whenever a key is present at runtime.
          services.pi-chat.openrouter.enable = lib.mkDefault true;
          services.pi-chat.openrouter.apiKeyFile = lib.mkDefault (
            pkgs.writeText "openrouter-api-key-placeholder" ""
          );

          # fw_cfg sysfs (/sys/firmware/qemu_fw_cfg) needs this driver.
          boot.kernelModules = [ "qemu_fw_cfg" ];

          # spaces-secrets-load creates the (empty placeholder) secret
          # file that pi-sessiond's LoadCredential reads. If the
          # launcher published a key over fw_cfg, overwrite the file with
          # it before the user session's pi-sessiond starts, so the
          # supervisor registers OpenRouter and its catalog reaches the
          # picker. No key -> ConditionPathExists fails -> stays local.
          systemd.services.spaces-openrouter-fwcfg = {
            description = "Stage the OpenRouter key passed via QEMU fw_cfg";
            after = [
              "spaces-secrets-load.service"
              "systemd-modules-load.service"
            ];
            wants = [ "spaces-secrets-load.service" ];
            wantedBy = [ "multi-user.target" ];
            unitConfig.ConditionPathExists = fwCfgPath;
            path = [ pkgs.coreutils ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              key="$(tr -d '\n\0' < ${fwCfgPath})"
              if [ -n "$key" ]; then
                printf '%s' "$key" > ${secretPath}
                chown root:users ${secretPath}
                chmod 0640 ${secretPath}
              fi
            '';
          };
        }
        # Outbound internet, but only when mode (A) isn't already forcing
        # it (avoids a double mkForce when both apply under --impure).
        (lib.mkIf (!useOpenrouter) internet)
      ];
    }
  ];
}
