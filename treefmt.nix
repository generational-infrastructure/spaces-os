_: {
  projectRootFile = "flake.nix";

  # Nix
  programs.nixfmt.enable = true;
  programs.deadnix.enable = true;
  programs.deadnix.no-lambda-pattern-names = true;
  programs.statix.enable = true;

  # Bash
  programs.shfmt.enable = true;
  programs.shellcheck.enable = true;

  # Python
  programs.ruff-format.enable = true;
  programs.ruff-check.enable = true;
  programs.ruff-check.extendSelect = [ "I" ];

  # JS/TS
  programs.prettier.enable = true;
  programs.prettier.includes = [
    "*.ts"
    "*.tsx"
    "*.js"
    "*.jsx"
  ];
  # QML's JavaScript dialect (.pragma library) is not valid ES.
  programs.prettier.excludes = [ "programs/pi-chat-plugin/MsgText.js" ];
}
