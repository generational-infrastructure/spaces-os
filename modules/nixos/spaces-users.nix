# Nix-managed per-user integration profiles — the pure-data option namespace
# (docs/agent-integrations-design.md §10.1). Declaring
#
#   spaces.users.<name>.integrations.<integration> = {
#     enable = true;                                   # defaults true once profiles set
#     profiles.<profile>.config.<field>  = "literal" | { file = "/path"; };
#     profiles.<profile>.secrets.<field> = { file = "/path"; };
#   };
#
# describes the SAME accounts the panel provisions at runtime, layered on top of
# the runtime store (never replacing it). This module defines OPTIONS ONLY: it
# emits no config beyond the `spaces.users` namespace. The spaces-integrations
# module consumes + lowers it into a root stager, a per-user staged credential
# tree, and managed.json (see ./spaces-integrations/{default,lib}.nix). Keeping
# it a pure data namespace lets a home-manager adapter reuse it unchanged.
{ lib, ... }:
let
  # config.<field> = "literal" | { file = "/path"; }. `file =` is the escape
  # hatch: the stager `cat`s the path at stage time so the value never enters
  # the world-readable Nix store. The path is a plain STRING (never a Nix
  # `path`, which would COPY the file into /nix/store — defeating the point).
  configFileSubmodule = lib.types.submodule {
    options.file = lib.mkOption {
      type = lib.types.str;
      description = ''
        Absolute path read at stage time into the staged config (both
        managed-config.toml and managed.json). Use this instead of a literal
        for anything you do not want copied into the world-readable Nix store.
        A plain string, never a Nix path — the content is resolved at runtime,
        not build time, so it is never written into /nix/store.
      '';
    };
  };

  # secrets.<field> = { file = "/path"; } — file reference ONLY, never a literal
  # (a literal secret would land in /nix/store). The stager COPIES the file
  # (0400, user-owned) into the unit's credential directory.
  secretFileSubmodule = lib.types.submodule {
    options.file = lib.mkOption {
      type = lib.types.str;
      description = ''
        Absolute path to the secret, COPIED (never symlinked) at stage time into
        the unit's credential directory as secret-<profile>-<field> (0400,
        user-owned). File reference only: a literal value is a type error, since
        it would otherwise be written into the world-readable Nix store.
      '';
    };
  };

  profileSubmodule = lib.types.submodule {
    options = {
      config = lib.mkOption {
        type = lib.types.attrsOf (lib.types.either lib.types.str configFileSubmodule);
        default = { };
        description = ''
          Non-secret connection fields for this profile, keyed by field name.
          Each value is EITHER a literal string OR `{ file = "/path"; }`.

          STORE FOOTGUN: a literal string is embedded verbatim in the Nix store,
          which is world-readable. Prefer `{ file = "/path"; }` for anything even
          mildly sensitive — the stager resolves it at stage time so the value
          never enters /nix/store.
        '';
      };
      secrets = lib.mkOption {
        type = lib.types.attrsOf secretFileSubmodule;
        default = { };
        description = ''
          Secret fields for this profile, keyed by field name. Each value is
          `{ file = "/path"; }` ONLY — a literal string is rejected. The stager
          copies the file into the unit's credential directory (0400, user-owned).
        '';
      };
    };
  };

  integrationSubmodule = lib.types.submodule (
    { config, ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          # Declaring accounts implies the integration should run, so `enable`
          # defaults to true once any profile is set; an explicit value wins.
          default = config.profiles != { };
          defaultText = lib.literalExpression "profiles != { }";
          description = ''
            Nix enable verdict for this integration for this user. Both `true`
            and `false` are authoritative: while a verdict is present the broker
            refuses runtime GUI enable/disable of this integration. Defaults to
            true once any profile is declared.
          '';
        };
        profiles = lib.mkOption {
          type = lib.types.attrsOf profileSubmodule;
          default = { };
          description = ''
            Nix-managed accounts for this integration, keyed by profile name. A
            managed profile is complete and fully read-only in the GUI, and
            shadows (never deletes) a same-named user profile. Allowed only on
            integrations that declare config/secret fields; a field-less
            integration (e.g. signal) accepts `enable` only.
          '';
        };
      };
    }
  );
in
{
  options.spaces.users = lib.mkOption {
    default = { };
    description = ''
      Nix-managed, per-user integration profiles (agent-integrations §10). A
      PURE DATA namespace: this module defines the options; the
      spaces-integrations module lowers them into a root stager and a per-user
      staged credential tree under /run/spaces-integrations-managed. Keyed by
      username (must be a normal user in users.users).
    '';
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.integrations = lib.mkOption {
          type = lib.types.attrsOf integrationSubmodule;
          default = { };
          description = ''
            Nix-managed integrations for this user, keyed by integration name
            (must exist in services.spaces-integrations.integrations).
          '';
        };
      }
    );
  };
}
