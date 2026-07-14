# Shared child-process wiring for the pi-sessiond executor module.
#
# Factored out of ./default.nix so the option surface and the child/settings
# composition stay separable. The one module runs the daemon as a `--user`
# service (the desktop loopback default or a server's per-user remote
# executor); this builds the per-session pi child's extension list + the
# settings.json it reads, and resolves the Landlock launcher.
#
#   - Bundled extensions (llama-swap-discover, spaces-integrations,
#     openrouter-proxy) come from the pi-chat-extensions flake package, which
#     owns the per-extension store-path materialisation.
#   - `materialize` copies a USER-supplied extension path (the `extensions`
#     option) to its own tracked store path — see
#     packages/pi-chat-extensions/default.nix for why a bare `toString` of a
#     flake-relative path would break nix's reference scan. Paths already in
#     the store (the option's default, prebuilt extension derivations) pass
#     through untouched.
#   - `mkChild` composes the child's extension list (llama-swap-discover is
#     always added so the child registers the `local` provider from
#     LLAMA_SWAP_BASE_URL; openrouter-proxy only when enabled — it registers
#     `openrouter` via the supervisor's credential proxy, so the real key
#     never enters the sandbox) and generates the settings.json the child
#     reads via PI_CODING_AGENT_DIR.
{
  pkgs,
  lib,
  inputs,
}:
let
  jsonFormat = pkgs.formats.json { };

  extensionsPkg = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-chat-extensions;

  materialize =
    e:
    if lib.isStorePath e then
      e
    else
      builtins.path {
        path = e;
        name = baseNameOf (toString e);
      };

  llamaSwapDiscover = extensionsPkg.extensions."llama-swap-discover";
  openrouterProxyExt = extensionsPkg.extensions."openrouter-proxy";
  # The agent-facing half of the integrations system (generic-mcp design §4): a
  # generic MCP client that connects to the standalone gateway over
  # SPACES_INTEGRATION_GATEWAY_SOCKET and registers its aggregated tools. Always
  # loaded; inert when the gateway socket is unset/unreachable (no tools).
  spacesIntegrationsExt = extensionsPkg.extensions."spaces-integrations";
in
{
  inherit jsonFormat;

  # The bundled-extensions flake package (also carries the memory extension as
  # `piChatExtensions.memory`), so ./default.nix reuses the same instance.
  piChatExtensions = extensionsPkg;

  # The per-session Landlock launcher (docs/landlock-sandbox-design.md §6): the
  # sole sandbox path. It self-applies the deny-by-default Landlock domain
  # before exec'ing pi — no userns, no nsresourced, no reboot. The child runs
  # as the user (the supervisor's own uid); Landlock confines but never drops
  # privilege.
  landlockExec = lib.getExe inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.landlock-exec;

  # Compose a session child's extension list + the settings.json it reads.
  #   extensions    — the module's `extensions` option (flake-relative paths).
  #   extra         — already-built extensions specific to one deployment
  #                   (e.g. the desktop's in-process memory extension package).
  #   openrouter    — add the openrouter-proxy extension.
  #   baseSettings  — extra settings.json keys merged UNDER the module-owned
  #                   ones (the loopback's `piSettings` escape hatch).
  #   ownedSettings — extra module-owned keys that WIN over baseSettings
  #                   (the loopback's `skills` list).
  mkChild =
    {
      package,
      extensions,
      defaultProvider,
      defaultModel,
      name,
      extra ? [ ],
      openrouter ? false,
      baseSettings ? { },
      ownedSettings ? { },
    }:
    let
      childExtensions =
        (map materialize extensions)
        ++ extra
        ++ [
          llamaSwapDiscover
          spacesIntegrationsExt
        ]
        ++ lib.optional openrouter openrouterProxyExt;
    in
    {
      inherit childExtensions;
      piBin = lib.getExe' package.pi "pi";
      piSettings = jsonFormat.generate "${name}-settings.json" (
        baseSettings
        // {
          extensions = map toString childExtensions;
          inherit defaultProvider defaultModel;
          quietStartup = true;
          enableInstallTelemetry = false;
        }
        // ownedSettings
      );
    };
}
