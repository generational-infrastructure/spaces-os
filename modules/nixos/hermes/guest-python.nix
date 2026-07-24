# Writable "pip just works" python for Hermes guests: a venv at
# <stateDir>/.venv over a nixpkgs python-with-packages interpreter
# (--system-site-packages), recreated whenever the interpreter env
# changes (pip-installed extras are lost then). Manylinux wheels work
# via nix-ld (standalone executables) plus LD_LIBRARY_PATH (extension
# modules dlopen'd by the nix-built interpreter — exported for login
# shells, published as `wheelLibraryPath` for service units).
# Used by ./guest.nix; exercised by the debug.hermes-vm test.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.hermes-python;

  pythonEnv = cfg.python.withPackages cfg.packages;

  # Shared libs for `pip install`ed manylinux wheels (see header).
  nixLdLibraries = with pkgs; [
    stdenv.cc.cc
    zlib
    zstd
    openssl
    curl
    expat
    libxml2
    libxslt
    libffi
    bzip2
    ncurses
    fontconfig
    freetype
  ];
in
{
  options.services.hermes-python = with lib; {
    enable = mkEnableOption "a writable, pip-capable python venv over a nixpkgs interpreter";

    user = mkOption {
      type = types.str;
      description = "Owner of the venv.";
    };

    group = mkOption {
      type = types.str;
      default = "users";
      description = "Group owner of the venv.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/hermes";
      description = "Directory holding the .venv.";
    };

    python = mkOption {
      type = types.package;
      default = pkgs.python3;
      defaultText = literalExpression "pkgs.python3";
      description = "Base interpreter the venv is built from.";
    };

    packages = mkOption {
      type = types.functionTo (types.listOf types.package);
      default = _ps: [ ];
      description = "Python libraries preinstalled (nix-built, exposed via --system-site-packages).";
    };

    venv = mkOption {
      type = types.str;
      readOnly = true;
      default = "${cfg.stateDir}/.venv";
      description = "Path of the provisioned venv (read-only).";
    };

    wheelLibraryPath = mkOption {
      type = types.str;
      readOnly = true;
      default = lib.makeLibraryPath nixLdLibraries;
      defaultText = literalExpression "lib.makeLibraryPath nixLdLibraries";
      description = ''
        LD_LIBRARY_PATH value that lets manylinux extension modules load
        under the nix-built interpreter. Exported for login shells here;
        service units that run the venv python must set it themselves
        (read-only).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.hermes-python-venv = {
      description = "Hermes python venv (pip-writable)";
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = [ cfg.stateDir ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        venv=${cfg.venv}
        mkdir -p ${cfg.stateDir}
        if [ ! -x "$venv/bin/python" ] \
           || [ "$(cat "$venv/.nix-python" 2>/dev/null || true)" != "${pythonEnv}" ]; then
          rm -rf "$venv"
          ${pythonEnv}/bin/python -m venv --system-site-packages "$venv"
          printf '%s' "${pythonEnv}" > "$venv/.nix-python"
          chown -R ${cfg.user}:${cfg.group} "$venv"
        fi
      '';
    };

    # manylinux wheels from pip need a link-loader + common shared libs
    programs.nix-ld.enable = true;
    programs.nix-ld.libraries = nixLdLibraries;

    # interactive/login shells get the writable venv first, and the wheel
    # shared libs (see header for why LD_LIBRARY_PATH and not nix-ld)
    environment.extraInit = ''
      export PATH="${cfg.venv}/bin:$PATH"
      export LD_LIBRARY_PATH="${cfg.wheelLibraryPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    '';
  };
}
