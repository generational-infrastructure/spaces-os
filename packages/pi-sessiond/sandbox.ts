// Builds the command that launches a session's `pi --mode rpc`.
//
// Each session runs inside a `systemd-run` transient unit carrying the same
// sandbox bouquet the desktop panel's PiSession._buildCommand applies
// (docs/remote-pi-design.md §8): ProtectHome=tmpfs + narrowed BindPaths +
// the kernel/namespace protection set, so a remote executor confines pi just
// like the desktop does. `--pipe` wires the unit's stdio back to the daemon
// for the RPC channel. Kept pure (no process/fs access) so it is unit-testable.

export interface SpawnConfig {
  systemdRun: string; // path to systemd-run (or a stub, in tests)
  piBin: string;
  sessionId: string;
  sessionDir: string; // pi --session-dir target (persisted session.jsonl; bound rw)
  workdir: string; // per-session cwd / workspace (bound rw)
  agentDir: string; // PI_CODING_AGENT_DIR (bound rw when sandboxed)
  llmUrl: string;
  provider: string;
  model: string;
  memoryHigh: string;
  path: string; // PATH to forward into the unit
  trusted: boolean; // skip filesystem narrowing (ProtectHome) when true
  continueSession: boolean; // pass pi --continue (resume the committed jsonl)
}

export interface SpawnCommand {
  argv: string[];
  // Env for the *spawned process*. When sandboxed, pi's env travels via
  // systemd-run --setenv (here it's empty and the daemon just inherits its
  // own env for systemd-run itself).
  env: Record<string, string>;
}

function piArgs(c: SpawnConfig): string[] {
  const args = [
    "--mode",
    "rpc",
    "--provider",
    c.provider,
    "--session-dir",
    c.sessionDir,
    "--offline",
    "--no-context-files",
  ];
  if (c.model) args.push("--model", c.model);
  // Resume the most recent committed jsonl in --session-dir. Only when one
  // exists: on a fresh session the dir is empty and pi's --continue is noisy
  // (matches the desktop panel's PiSession._buildCommand).
  if (c.continueSession) args.push("--continue");
  return args;
}

export function buildSpawnCommand(c: SpawnConfig): SpawnCommand {
  // Each session runs inside a systemd-run transient unit; --pipe wires its
  // stdio back to the daemon. pi's env travels via --setenv (the unit gets a
  // clean env), so the daemon just inherits its own env for systemd-run.
  const argv = [
    c.systemdRun,
    "--pipe",
    "--quiet",
    "--collect",
    "--service-type=exec",
    `--unit=pi-sessiond-${c.sessionId}.service`,
    `--working-directory=${c.workdir}`,
    `--setenv=PI_CODING_AGENT_DIR=${c.agentDir}`,
    `--setenv=LLAMA_SWAP_BASE_URL=${c.llmUrl}`,
    "--setenv=PI_OFFLINE=1",
    "--setenv=PI_TELEMETRY=0",
    `--setenv=HOME=${c.agentDir}`,
    `--setenv=PATH=${c.path}`,
    `--property=BindPaths=${c.workdir}:${c.workdir}`,
    `--property=BindPaths=${c.sessionDir}:${c.sessionDir}`,
    "--property=PrivateTmp=true",
    "--property=PrivateDevices=true",
    "--property=ProtectKernelTunables=true",
    "--property=ProtectKernelModules=true",
    "--property=ProtectKernelLogs=true",
    "--property=ProtectControlGroups=true",
    "--property=ProtectClock=true",
    "--property=ProtectProc=invisible",
    "--property=NoNewPrivileges=true",
    "--property=RestrictSUIDSGID=true",
    "--property=LockPersonality=true",
    "--property=RestrictNamespaces=true",
    "--property=SystemCallArchitectures=native",
    `--property=MemoryHigh=${c.memoryHigh}`,
  ];
  // Trusted sessions skip filesystem narrowing; the kernel/namespace
  // protections above still apply. Untrusted: hide the real home, then bind
  // the writable agent dir back (pi mkdir's settings.json.lock there).
  if (!c.trusted) {
    argv.push("--property=ProtectHome=tmpfs");
    argv.push(`--property=BindPaths=${c.agentDir}:${c.agentDir}`);
  }
  argv.push("--", c.piBin, ...piArgs(c));
  return { argv, env: {} };
}
