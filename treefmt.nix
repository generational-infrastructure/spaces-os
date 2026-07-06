_: {
  projectRootFile = "flake.nix";

  # Nix
  programs.nixfmt.enable = true;
  programs.deadnix.enable = true;
  programs.deadnix.no-lambda-pattern-names = true;
  programs.statix.enable = true;
  programs.flake-edit.enable = true;

  # Bash
  programs.shfmt.enable = true;
  programs.shellcheck.enable = true;

  # Python: rule selection lives in the repo-root ruff.toml (single source
  # of truth); ruff resolves it for every file treefmt hands it.
  programs.ruff-format.enable = true;
  programs.ruff-check.enable = true;

  # JS/TS
  programs.prettier.enable = true;
  programs.prettier.includes = [
    "*.ts"
    "*.tsx"
    "*.js"
    "*.jsx"
  ];
  # QML's JavaScript dialect (.pragma library) is not valid ES.
  programs.prettier.excludes = [
    "programs/pi-chat/MsgText.js"
    "programs/pi-chat/Msg.js"
    "programs/pi-chat/BarParse.js"
    "programs/pi-chat/Reducer.js"
    "programs/pi-chat/SessionRegistry.js"
    # Qt Linguist translation source: a .ts file, but XML, not TypeScript.
    "packages/calamares-spaces-extensions/files/branding/spaces-os/lang/calamares-spaces-os_en.ts"
  ];
}
