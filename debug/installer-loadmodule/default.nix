# Integration test: drive the patched Calamares `nixos` job module
# headlessly via the upstream `loadmodule` test executable.
#
# This exercises the *real* Calamares Python binding (libcalamares) +
# YAML-seeded globalstorage path — the layer that the lightweight
# `installer-config-gen` unit test stubs out. We:
#
#   1. Boot a small NixOS VM with calamares-with-tests +
#      calamares-distro-extensions installed.
#   2. Mount a fresh ext4 disk at `/mnt` so `nixos-generate-config`
#      and the file-write side-effects in `run()` have a writable
#      target. (The script no longer needs anything staged on the
#      live medium — the distro flake store path is baked into
#      `main.py` at extensions-package build time.)
#   3. Stub `nix-build` and `nixos-install` to no-ops — we're
#      verifying main.py's config-generation path, not realising the
#      installed system's closure (the ISO-boot test exercises that).
#      Both stubs exit 0 so `run()` returns success.
#   4. Run loadmodule with a YAML fixture mirroring the keys
#      Calamares writes into globalstorage during a real GUI session.
#   5. Assert every expected output file exists, that the generated
#      Nix parses, and that `default.nix` references the expected
#      distro store path.
{
  pkgs,
  flake,
  inputs,
  ...
}:
let
  inherit (pkgs) lib;

  cwt = pkgs.callPackage ./calamares-with-tests { };
  ext = pkgs.callPackage ../../packages/calamares-distro-extensions { };

  # Direct inputs distro declares, read straight out of distro's
  # flake.lock so the test mirrors what installer-iso.nix computes.
  # Hardcoding the list here would silently rot when distro grows or
  # drops an input.
  distroLock = builtins.fromJSON (builtins.readFile "${flake.lib.distroSrc}/flake.lock");
  distroDirectInputs = builtins.attrNames distroLock.nodes.root.inputs;
  inputOverrides = lib.genAttrs (builtins.filter (n: inputs ? ${n}) distroDirectInputs) (
    n: builtins.toString inputs.${n}.outPath
  );
  installConfig = pkgs.writeText "calamares-distro-install.json" (
    builtins.toJSON {
      distroFlake = toString flake.lib.distroSrc;
      inherit inputOverrides;
    }
  );

  # `main.py` ends with `pkexec nix --extra-experimental-features … build …`
  # followed by `pkexec nixos-install --system <toplevel>`. Realising the
  # full installed-system closure is irrelevant to *this* test (the
  # GUI E2E test exercises that path); stub `nix build` to a no-op that
  # prints a plausible toplevel path. Other nix subcommands pass through
  # to the real CLI in case main.py grows additional invocations.
  fakeNix = pkgs.writeShellScriptBin "nix" ''
    for a in "$@"; do
      if [ "$a" = build ]; then
        echo "[fake] nix $*" >&2
        echo /tmp/fake-toplevel
        exit 0
      fi
    done
    exec ${pkgs.nix}/bin/nix "$@"
  '';
  fakeNixosInstall = pkgs.writeShellScriptBin "nixos-install" ''
    echo "[fake] nixos-install $*" >&2
    exit 0
  '';

  # Globalstorage fixture matching what Calamares' GUI modules
  # populate during a typical EFI install on a single ext4 root.
  globalYaml = pkgs.writeText "global.yaml" ''
    rootMountPoint: /mnt
    firmwareType: efi
    bootLoader:
      installPath: /boot
    partitions:
      - mountPoint: /
        fs: ext4
        fsName: ext4
        claimed: true
        device: /dev/vdb1
        uuid: 00000000-0000-0000-0000-000000000001
    hostname: ai-desktop
    username: alice
    fullname: Alice Example
    locationRegion: Europe
    locationZone: Berlin
    localeConf:
      LANG: en_US.UTF-8/UTF-8
      LC_ADDRESS: en_US.UTF-8/UTF-8
      LC_IDENTIFICATION: en_US.UTF-8/UTF-8
      LC_MEASUREMENT: en_US.UTF-8/UTF-8
      LC_MONETARY: en_US.UTF-8/UTF-8
      LC_NAME: en_US.UTF-8/UTF-8
      LC_NUMERIC: en_US.UTF-8/UTF-8
      LC_PAPER: en_US.UTF-8/UTF-8
      LC_TELEPHONE: en_US.UTF-8/UTF-8
      LC_TIME: en_US.UTF-8/UTF-8
    keyboardLayout: us
    keyboardVariant: ""
    keyboardVConsoleKeymap: us
  '';
in
pkgs.testers.runNixOSTest {
  name = "installer-loadmodule";

  nodes.machine = _: {
    # Calamares + our forked extensions + the loadmodule test runner.
    environment.systemPackages = [
      cwt
      ext
      fakeNix
      fakeNixosInstall
      pkgs.nixos-install-tools # nixos-generate-config
      pkgs.parted
      pkgs.e2fsprogs
      pkgs.kbd # loadkeys
      pkgs.jq # flake.lock validation
      # `main.py` shells out via `pkexec` to gain root for
      # nixos-generate-config / nixos-install / chmod. The test VM
      # already runs the script as root, so route every `pkexec` to
      # plain exec — no privilege escalation needed.
      (pkgs.writeShellScriptBin "pkexec" ''exec "$@"'')
    ];

    # Stage the install-config JSON main.py reads at runtime. Putting
    # it under /etc/calamares-distro means the package itself stays
    # independent of the distro flake source path; pulling distroSrc
    # in via this etc entry keeps it alive in the VM's nix store
    # without going through the calamares derivation.
    environment.etc."calamares-distro/install.json".source = installConfig;

    # `pkexec` invoked by root just runs the command, so we don't
    # need a polkit rule — the test drives loadmodule as root.

    # Extra disk for /mnt. virtualisation.qemu.options is too low
    # level; use the test framework's emptyDiskImages.
    virtualisation.emptyDiskImages = [ 2048 ];
    virtualisation.memorySize = 2048;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    # Format and mount the secondary disk at /mnt — nixos-generate-config
    # walks /mnt looking for filesystems, and main.py writes its outputs
    # under /mnt/etc/nixos.
    machine.succeed(
      "parted -s /dev/vdb mklabel gpt mkpart root ext4 1MiB 100%",
      "mkfs.ext4 -F /dev/vdb1",
      "mkdir -p /mnt",
      "mount /dev/vdb1 /mnt",
    )

    # No staging assertions: main.py reads no paths off /iso anymore.

    # Drive Calamares' nixos job module against the YAML fixture.
    # `--global` seeds globalstorage; the positional arg is a module
    # name that loadmodule resolves against `./`, `src/modules/`,
    # `modules/`, and `<calamares>/lib/calamares/modules/` (the last
    # path is baked in at build time). Our fork ships under a
    # *different* store path than calamares-with-tests, so cd into
    # our extensions tree's `lib/calamares/` and pass `modules/nixos`
    # so the `./` prefix resolves to our module.
    machine.succeed(
      "cd ${ext}/lib/calamares && "
      "loadmodule -P --global ${globalYaml} modules/nixos 2>&1 | tee /tmp/loadmodule.log"
    )

    print(machine.succeed("cat /tmp/loadmodule.log"))
    print(machine.succeed("ls -laR /mnt/etc 2>&1 || true"))
    # Verify every output file the patched run() should have written.
    machine.succeed("test -f /mnt/etc/nixos/configuration.nix")
    machine.succeed("test -f /mnt/etc/nixos/hardware-configuration.nix")
    machine.succeed("test -f /mnt/etc/nixos/flake.nix")
    machine.fail("test -e /mnt/etc/nixos/default.nix")  # superseded by wrapper flake
    machine.succeed("test -f /mnt/etc/nixos/flake.lock")

    # Wrapper flake.lock pins distro AND distro's direct inputs to
    # staged store paths. If the lock graph is malformed, eval breaks
    # with a confusing "attribute … missing" later; a structural check
    # here catches the wiring at the unit level.
    machine.succeed("jq . /mnt/etc/nixos/flake.lock > /dev/null")
    machine.succeed(
      "test \"$(jq -r .nodes.distro.locked.path /mnt/etc/nixos/flake.lock)\" "
      "= '${flake.lib.distroSrc}'"
    )
    machine.succeed(
      "test \"$(jq -r .nodes.distro.original.type /mnt/etc/nixos/flake.lock)\" "
      "= 'github'"
    )
    # Every direct input distro declares MUST appear as a path-locked
    # node. The list is derived from distro's own flake.lock at Nix
    # eval time so it stays in sync. Look up each input via
    # `.nodes.distro.inputs.<name>` to handle node renames (e.g.
    # `treefmt-nix_2` for follow-deduplicated nodes).
    for inp in [${lib.concatMapStringsSep ", " (n: ''"${n}"'') distroDirectInputs}]:
        machine.succeed(
            "node=$(jq -r --arg n " + f"\"{inp}\"" + " "
            "'.nodes.distro.inputs[$n]' /mnt/etc/nixos/flake.lock); "
            "test \"$(jq -r --arg n \"$node\" "
            "'.nodes[$n].locked.type' /mnt/etc/nixos/flake.lock)\" "
            "= 'path'"
        )

    # Spot-check the content shape — the unit test asserts string
    # details exhaustively; here we only confirm the real-Calamares
    # path produced a config of the same family.
    machine.succeed(
      "grep -q 'inputs.distro.url = \"github:generational-infrastructure/distro\"' "
      "/mnt/etc/nixos/flake.nix"
    )
    machine.succeed("grep -q 'inputs.distro.lib.mkSystem' /mnt/etc/nixos/flake.nix")
    machine.succeed("grep -q 'nixosConfigurations.ai-desktop' /mnt/etc/nixos/flake.nix")
    machine.succeed(
      "grep -q 'hostName = \"ai-desktop\"' /mnt/etc/nixos/flake.nix"
    )
    machine.succeed("grep -q 'users.users.alice' /mnt/etc/nixos/configuration.nix")
    machine.succeed(
      "grep -q 'services.greetd.settings.default_session.user = \"alice\"' "
      "/mnt/etc/nixos/configuration.nix"
    )


    # No DE branching survived the patch.
    machine.fail("grep -q 'desktopManager.gnome' /mnt/etc/nixos/configuration.nix")
    machine.fail("grep -q 'desktopManager.plasma6' /mnt/etc/nixos/configuration.nix")

    # Generated files are syntactically valid. Full evaluation would
    # require every transitive input of the distro flake to be in the
    # VM's store; here we settle for a parse check, which catches
    # template-substitution mishaps (stray @@@@, malformed multi-line
    # strings, etc.) without hauling nixpkgs into the VM closure.
    machine.succeed("nix-instantiate --parse /mnt/etc/nixos/configuration.nix > /dev/null")
    machine.succeed("nix-instantiate --parse /mnt/etc/nixos/flake.nix > /dev/null")
    machine.succeed(
      "nix-instantiate --parse /mnt/etc/nixos/hardware-configuration.nix > /dev/null"
    )
  '';
}
