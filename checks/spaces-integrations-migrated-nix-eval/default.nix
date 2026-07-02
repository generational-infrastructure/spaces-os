# Contract for the migrated skill integrations (mail / caldav / contacts),
# docs/agent-integrations-skill-migration-plan.md.
#
# Evaluates the REAL host declarations (hosts/test-machine/integrations.nix)
# through the spaces-integrations module and asserts, per integration, the
# world-readable definition the broker + gateway + panel consume:
#   - config + secrets field schema matches the server's expectations;
#   - the autoRun allowlist is READ-ONLY tools only (writes stay confirm-per-call
#     — the design's send/put/delete approval gate);
#   - multiProfile is on (multi-account).
#
# Pure nix-eval (definitions are lowered from the manifest; no server build).
{ pkgs, inputs, ... }:
let
  inherit (inputs.nixpkgs) lib;
  integLib = import ../../modules/nixos/spaces-integrations/lib.nix { inherit pkgs lib; };

  system = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = {
      inherit inputs;
      flake = inputs.self;
    };
    modules = [
      inputs.self.nixosModules.spaces-integrations
      ../../hosts/test-machine/integrations.nix
      {
        nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
        networking.hostName = "migrated-defs-fixture";
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        boot.loader.grub.enable = false;
        system.stateVersion = "26.05";
      }
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

  caldav = defOf "caldav";
  contacts = defOf "contacts";
  mail = defOf "mail";

  # autoRun must be exactly the declared read-only set; the write tools below
  # must NEVER be auto-run (they stay confirm-per-call).
  hasNone = list: set: !(lib.any (x: lib.elem x set) list);
in
# ── caldav ──────────────────────────────────────────────────────────────────
assert caldav.multiProfile;
assert caldav.config ? url && caldav.config ? user;
assert caldav.secrets ? password;
assert
  caldav.autoRun == [
    "list"
    "get"
    "etag"
  ];
assert hasNone [ "put" "delete" ] caldav.autoRun;
# ── contacts ────────────────────────────────────────────────────────────────
assert contacts.multiProfile;
assert contacts.config ? server && contacts.config ? user && contacts.config ? book;
assert !contacts.config.book.required; # optional field
assert contacts.secrets ? password;
assert
  contacts.autoRun == [
    "discover"
    "search"
    "get"
  ];
assert hasNone [ "new" "edit" "delete" ] contacts.autoRun;
# ── mail ────────────────────────────────────────────────────────────────────
assert mail.multiProfile;
assert mail.config ? email && mail.config ? imap_host && mail.config ? smtp_host;
assert mail.config.email.required && !mail.config.imap_port.required;
assert mail.secrets ? password;
assert
  mail.autoRun == [
    "envelope_list"
    "message_read"
  ];
assert hasNone [ "message_send" ] mail.autoRun;
# ── the definition never leaks a command or secret value ────────────────────
assert !(caldav ? command) && !(mail ? command);
pkgs.runCommand "spaces-integrations-migrated-nix-eval-test" { } ''
  echo "migrated integration definitions OK (caldav/contacts/mail: schema + read-only autoRun)"
  touch "$out"
''
