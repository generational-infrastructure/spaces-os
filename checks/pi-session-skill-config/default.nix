# Skill-config prompt round-trip test.
#
# Boots the skill-config-daemon and an offscreen quickshell with a
# test shell that subscribes to the daemon socket. The driver runs
# the REAL `skill-config request-input` CLI binary (same one pi uses
# from inside its pi-sessiond sandbox) against a staged test-skill, asserts the
# prompt bubble appears, submits a value, and verifies the CLI exits 0
# with the value persisted to config.toml.
#
# No pi process, no pi-sessiond, no LLM, no compositor. ~5s.
{ pkgs, inputs, ... }:
let
  skillConfigDaemon = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.skill-config-daemon;
  skillConfig = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.skill-config;
in
(import ../../lib/quickshell-check.nix pkgs).mkQuickshellCheck {
  name = "pi-session-skill-config";
  dir = ./.;
  extraInputs = [
    skillConfigDaemon
    skillConfig
  ];
  extraArgs = [
    (pkgs.lib.getExe skillConfigDaemon)
    (pkgs.lib.getExe skillConfig)
  ];
}
