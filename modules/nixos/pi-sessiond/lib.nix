# Shared child-process wiring for the two pi-sessiond deployment modules.
#
# Both modules — the system/remote executor (./default.nix) and the desktop
# loopback user service (../pi-sessiond-local.nix) — run the SAME daemon
# binary: a supervisor that spawns one `pi --mode rpc` child per session and
# confines it with the pi-landlock-exec launcher. Only the systemd shape
# (system vs user manager, uid handling, supervisor hardening) and the option
# surface differ; this factors out the bits that are identical between them.
#
#   - `materialize` copies each extension to its OWN tracked store path. A
#     bare `toString` of a flake-relative path embeds the whole-flake
#     `…-source` path, which nix's reference scanner does NOT capture as a
#     runtime dependency of settings.json — so the file would be absent from
#     the executor's store at runtime and pi would silently skip the extension
#     (the `local` provider never registers). `builtins.path` copies just the
#     one file to a standalone, tracked store path.
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

  materialize =
    e:
    builtins.path {
      path = e;
      name = baseNameOf (toString e);
    };

  llamaSwapDiscover = materialize ../pi-chat/extensions/llama-swap-discover.ts;
  openrouterProxyExt = materialize ../pi-chat/extensions/openrouter-proxy.ts;
in
{
  inherit jsonFormat;

  # The per-session Landlock launcher (docs/landlock-sandbox-design.md §6):
  # the sole sandbox path for BOTH executors. It self-applies the deny-by-
  # default Landlock domain before exec'ing pi — no userns, no nsresourced,
  # no reboot. The system executor additionally drops the unit to the
  # pi-session uid via systemd-run --uid; the desktop runs it as the user.
  landlockExec = lib.getExe inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-landlock-exec;

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
        ++ [ llamaSwapDiscover ]
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
