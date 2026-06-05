// Builds the `systemd-run` command that confines a single `bash` tool
// invocation.
//
// With SDK-embedded execution (docs/remote-pi-design.md §2/§8) the daemon runs
// pi in-process, so the per-session subprocess sandbox is gone. We reintroduce
// confinement at the tool boundary: pi's built-in `bash` is replaced by a tool
// whose BashOperations wraps every command in a `systemd-run` transient unit
// carrying the same bouquet the desktop panel's PiSession._buildCommand applied
// (ProtectHome=tmpfs + narrowed BindPaths + the kernel/namespace protection
// set). `--pipe --wait` wires the unit's stdio back so output streams and the
// exec resolves on completion. Kept pure (no process/fs access) so it is
// unit-testable.

export interface BashSandboxConfig {
  systemdRun: string; // path to systemd-run (or a stub, in tests)
  workdir: string; // the command's cwd; bound rw and narrowed to
  agentDir: string; // pi's agent dir (HOME); bound rw when untrusted
  memoryHigh: string; // MemoryHigh= for the unit
  trusted: boolean; // skip filesystem narrowing (ProtectHome) when true
  extraBinds?: string[]; // additional rw paths to bind (e.g. the session dir)
}

// The kernel/namespace protection set applied to every sandboxed command,
// trusted or not (it never narrows the filesystem, only hardens the kernel
// surface). Shared so the bouquet stays in one place.
function hardeningProps(c: BashSandboxConfig): string[] {
  return [
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
}

// argv that runs `bash -c <command>` inside a transient confinement unit.
// The command travels as a single argv element after `--`, so there is no
// nested-shell quoting to get wrong.
export function buildBashSandboxArgv(
  c: BashSandboxConfig,
  command: string,
): string[] {
  const argv = [
    c.systemdRun,
    "--pipe",
    "--quiet",
    "--collect",
    "--wait",
    "--service-type=exec",
    `--working-directory=${c.workdir}`,
    `--property=BindPaths=${c.workdir}:${c.workdir}`,
    ...(c.extraBinds ?? []).map((p) => `--property=BindPaths=${p}:${p}`),
    ...hardeningProps(c),
  ];
  // Trusted sessions skip filesystem narrowing; the kernel/namespace
  // protections above still apply. Untrusted: hide the real home, then bind
  // the writable agent dir back (pi/tools mkdir lock dirs there).
  if (!c.trusted) {
    argv.push("--property=ProtectHome=tmpfs");
    argv.push(`--property=BindPaths=${c.agentDir}:${c.agentDir}`);
  }
  argv.push("--", "bash", "-c", command);
  return argv;
}
