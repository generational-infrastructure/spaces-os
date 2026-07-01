# Realizes this flake's transitive input closure as a single linkFarm
# derivation — one entry per deduplicated input source tree. Building it
# forces every input (and input-of-input) to be fetched/realized, so a
# populated binary cache lets evals resolve inputs without hitting upstream
# forges, and CI fails fast when the lock points at something unfetchable.
#
# Inlined from a-kenji/inputs-cache's `mkInputsCheck` — its flake-parts
# module doesn't fit this blueprint-based flake, and we only want the
# transitive-closure-of-all-inputs behaviour, so the options are dropped.
{ pkgs, inputs, ... }:
let
  entriesOf =
    attrs:
    map (name: {
      inherit name;
      value = attrs.${name};
    }) (builtins.attrNames attrs);

  mkNode = entry: {
    key = entry.value.outPath;
    inherit (entry) name value;
    inherit (entry.value) outPath;
  };

  # Deduplicated transitive closure of every input's store path, `self`
  # excluded. `flake = false` inputs carry no `inputs` attr, so they
  # terminate the walk as leaves.
  nodes = builtins.genericClosure {
    startSet = map mkNode (entriesOf (removeAttrs inputs [ "self" ]));
    operator = node: if node.value ? inputs then map mkNode (entriesOf node.value.inputs) else [ ];
  };
in
# Suffix each name with its store hash to keep it unique: `nixpkgs-3a2vdn5i`.
pkgs.linkFarm "inputs" (
  map (node: {
    name = "${node.name}-${
      builtins.substring 0 8 (builtins.unsafeDiscardStringContext (baseNameOf node.outPath))
    }";
    path = node.outPath;
  }) nodes
)
