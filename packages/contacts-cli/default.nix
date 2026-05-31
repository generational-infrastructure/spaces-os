{ inputs, pkgs, ... }:
let
  inherit (inputs.self.packages.${pkgs.stdenv.hostPlatform.system}) skill-config;

  # The raw CardDAV client. Dependencies are vendored (./vendor) so the
  # build needs no network and vendorHash can stay null.
  contacts-cli = pkgs.buildGoModule {
    pname = "contacts-cli";
    version = "0.1.0";
    src = ./.;
    vendorHash = null;
    meta.mainProgram = "contacts-cli";
  };
in
# `contacts` wraps the raw client, pulling per-profile credentials from
# skill-config and handing them to contacts-cli via its CONTACTS_* env vars.
pkgs.writeShellApplication {
  name = "contacts";
  runtimeInputs = [
    contacts-cli
    skill-config
  ];
  text = builtins.readFile ./contacts.sh;
  meta.mainProgram = "contacts";
}
