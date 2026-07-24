# spaces.openrouter — the host-wide OpenRouter API key shared by every
# agent surface (pi-chat staging, hermes microvm credentials). Options
# only, zero closure; safe in the base tree. Consumers stage/transport
# the key themselves.
{ config, lib, ... }:
{
  imports = [
    (lib.mkRenamedOptionModule
      [ "services" "pi-chat" "openrouter" "enable" ]
      [ "spaces" "openrouter" "enable" ]
    )
    (lib.mkRenamedOptionModule
      [ "services" "pi-chat" "openrouter" "apiKeyFile" ]
      [ "spaces" "openrouter" "apiKeyFile" ]
    )
  ];

  options.spaces.openrouter = {
    enable = lib.mkEnableOption "the shared OpenRouter API key for agent surfaces";
    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Host path to a file containing the OpenRouter API key (single
        line). Pass a runtime path (e.g. a sops/clan secret), not a
        store path, outside tests. pi-chat stages it under
        /run/spaces-secrets; hermes microvms ride it in as a systemd
        credential.
      '';
    };
  };

  config.assertions = [
    {
      assertion = !config.spaces.openrouter.enable || config.spaces.openrouter.apiKeyFile != null;
      message = "spaces.openrouter.apiKeyFile must be set when spaces.openrouter.enable = true.";
    }
  ];
}
