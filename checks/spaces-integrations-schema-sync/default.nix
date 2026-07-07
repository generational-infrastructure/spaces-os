# Pins the schema single-sourcing contract between the integration packages
# and the DEFAULT manifests the spaces-integrations module now ships
# (modules/nixos/spaces-integrations/defaults.nix). For EVERY default
# integration:
#   - the evaluated definition's config/secrets field schema equals the
#     schema.json its package exports (packages/integration-<name>/schema.json,
#     kept in sync with the Python module by that package's own pytest);
#   - every autoRun name is one of the package's exported tool names, so a
#     renamed or removed tool can never leave a stale allowlist entry behind.
#
# Pure nix-eval: schema.json is read from the flake source tree and the
# manifests are lowered through the spaces-integrations module (defaults now
# come with the module — no host import); no server build.
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  integLib = import ../../modules/nixos/spaces-integrations/lib.nix {
    inherit pkgs lib;
    inherit (inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-sessiond) seccompDenylist;
  };

  system = inputs.self.lib.mkEvalSystem {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = [
      inputs.self.nixosModules.spaces-integrations
      { networking.hostName = "schema-sync-fixture"; }
    ];
  };

  inherit (system.config.services.spaces-integrations) integrations;
  defOf =
    name:
    (integLib.mkIntegration {
      inherit name;
      manifest = integrations.${name};
      landlockPolicyCli = "unused";
      landlockExec = "unused";
    }).definition;

  schemaOf =
    name: builtins.fromJSON (builtins.readFile (../../packages + "/integration-${name}/schema.json"));

  inSync =
    name:
    let
      def = defOf name;
      schema = schemaOf name;
    in
    def.config == schema.config
    && def.secrets == schema.secrets
    && lib.all (t: lib.elem t schema.tools) def.autoRun;

  outOfSync = lib.filter (name: !inSync name) (lib.attrNames integrations);
in
assert lib.assertMsg (
  outOfSync == [ ]
) "integrations out of sync with their package schema.json: ${toString outOfSync}";
pkgs.runCommand "spaces-integrations-schema-sync-test" { } ''
  echo "manifest fields match the package schemas; autoRun within exported tools"
  touch "$out"
''
