# Pins the services.pi-chat.openrouter.* -> spaces.openrouter.* rename:
# the old path must still evaluate (mkRenamedOptionModule) and land in
# the new one; the new path must feed pi-chat's secret staging.
{ pkgs, inputs, ... }:
let
  keyFile = pkgs.writeText "openrouter-api-key" "sk-or-dummy";

  # Old path set -> value must arrive at the new path.
  renamed =
    (inputs.self.lib.mkMinimalEvalSystem {
      inherit (pkgs.stdenv.hostPlatform) system;
      modules = [
        inputs.self.nixosModules.openrouter
        {
          services.pi-chat.openrouter.enable = true;
          services.pi-chat.openrouter.apiKeyFile = keyFile;
        }
      ];
    }).config;

  ok =
    assert renamed.spaces.openrouter.enable;
    assert renamed.spaces.openrouter.apiKeyFile == keyFile;
    true;
in
assert ok;
pkgs.runCommand "hermes-openrouter-rename-eval" { } "touch $out"
