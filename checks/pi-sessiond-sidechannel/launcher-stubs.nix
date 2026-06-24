# Passthrough stand-ins for the two programs the daemon execs around every
# session — the systemd-run wrapper and the Landlock launcher — shared by the
# cheap checks that boot the real pi-sessiond in the Nix build sandbox (where
# neither a systemd manager nor kernel Landlock exists). Each strips the
# bookkeeping flags its real counterpart consumes (the unit/--setenv flags for
# systemd-run; `--json <policy>` for pi-landlock-exec) and execs the tail
# command unconfined. Real Landlock enforcement is asserted by
# checks/pi-sessiond-landlock — these are deliberately inert.
#
# Imported by sibling checks:
#   stubs = import ../pi-sessiond-sidechannel/launcher-stubs.nix { inherit pkgs; };
# then `${stubs.systemdRun}/bin/systemd-run` / `${stubs.landlockExec}/bin/pi-landlock-exec`.
{ pkgs }:
let
  mk =
    name: bin: src:
    pkgs.runCommandLocal name { nativeBuildInputs = [ pkgs.bash ]; } ''
      install -Dm755 ${src} $out/bin/${bin}
      patchShebangs $out/bin/${bin}
    '';
in
{
  systemdRun = mk "systemd-run-stub" "systemd-run" ./systemd-run-stub;
  landlockExec = mk "pi-landlock-exec-stub" "pi-landlock-exec" ./landlock-exec-stub;
}
