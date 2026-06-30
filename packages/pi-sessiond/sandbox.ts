// Builds the per-session sandbox: the `systemd-run` command that confines an
// entire pi runtime, plus the landlockconfig policy it carries
// (docs/landlock-sandbox-design.md §5/§6).
//
// The runtime-isolation refactor inverts pi-sessiond: the supervisor runs no
// model code and spawns one `pi --mode rpc` child per session inside a
// confinement unit. The model loop, every tool, `bash`, the file tools, and any
// extension all run there; the unit's only outward channel is the rpc pipe
// (`--pipe --wait` wires its stdio back to the supervisor's driver). `bash` is
// not special-cased — it inherits the session's domain. The runtime stays the
// user's own real uid and is confined by a self-applied Landlock domain, not a
// userns:
// no nsresourced, no idmap, no reboot. Kept pure (no process/fs access) so the
// argv + policy contracts are unit-testable.

// One skill-plumbing path the sandboxed pi runtime reaches (a socket, a
// skills-def dir, the skill-config store), mirroring the NixOS module option
// services.pi-sessiond.allowedPaths. The grant applies to the whole
// per-session Landlock domain — every tool/bash/extension inherits it, not a
// standalone bash sandbox. Paths arrive pre-expanded (systemd resolves %h/%t
// in the Environment= the module hands the daemon) and are folded into the
// session's Landlock FS allowlist by access mode. Landlock grants the real
// path in place (no remapping) and pi-landlock-exec skips a missing path
// non-fatally — so the bind-mount-era `target`/`optional` fields are gone.
export interface AllowedPath {
  source: string;
  mode: "ro" | "rw";
}

// ===========================================================================
// The Landlock policy + launcher unit (docs/landlock-sandbox-design.md §5/§6).
//
// The runtime stays a real uid and is confined by a self-applied Landlock
// domain (deny-by-default FS allowlist + TCP-port allowlist + IPC scoping),
// described by a landlockconfig policy and applied by `pi-landlock-exec`
// between `systemd-run` and `pi`.
//
// Two pure, unit-tested outputs: the policy JSON (the supervisor writes one per
// session, the launcher reads it) and the `systemd-run` argv (cgroup + seccomp
// denylist + kernel hardening, then the launcher + the pi child after a second
// `--`).

// /nix/store carries the runtime image, pi, node, and every skill CLI — the one
// executable grant. The runtime never writes it.
const LANDLOCK_RX_PARENTS = ["/nix/store"];
// DNS / TLS directories a TLS lib may *list* (CApath). read_dir is valid here
// because these are directories.
const LANDLOCK_ETC_RO_DIRS = ["/etc/ssl", "/etc/static/ssl"];
// DNS / name-resolution files. read_file only — granting the directory right
// read_dir on a regular file is inert and downgrades the whole ruleset to
// "partially enforced", which would mask a real kernel-ABI gap.
const LANDLOCK_ETC_RO_FILES = [
  "/etc/resolv.conf",
  "/etc/passwd",
  "/etc/group",
  "/etc/nsswitch.conf",
];
// Device essentials every libc/runtime expects. Character-device files, so they
// take file rights — not the directory read_write group.
const LANDLOCK_DEV_FILES = [
  "/dev/null",
  "/dev/zero",
  "/dev/urandom",
  "/dev/random",
  "/dev/tty",
];

// The seccomp denylist (design §5.4). Landlock leaves same-uid kernel objects
// exposed; seccomp closes them. Encoded once, here, and carried on the unit via
// `SystemCallFilter=` (no Landlock format covers syscalls). @system-service —
// which keeps the landlock_* syscalls the launcher needs (@sandbox) — is the
// allowlist baseline; this set is then subtracted.
export const LANDLOCK_DENY_SYSCALLS = [
  "ptrace",
  "process_vm_readv",
  "process_vm_writev",
  "keyctl",
  "request_key",
  "add_key",
  "shmget",
  "shmat",
  "shmdt",
  "shmctl",
  "mq_open",
  "mq_unlink",
  "mq_timedsend",
  "mq_timedreceive",
  "mq_notify",
  "mq_getsetattr",
  "bpf",
  "io_uring_setup",
  "userfaultfd",
  "perf_event_open",
  "kcmp",
];

// The session's deny-by-default allowlist, bucketed by path type so each grant
// carries exactly the access class its inode supports: a directory-only right
// (read_dir, make_*) on a file is inert and downgrades the whole ruleset to
// "partially enforced" — which must mean "the kernel lacks an ABI", not "we
// over-asked on a file". Anything absent is denied; that is the whole security
// statement. The /nix/store + /etc + /dev defaults are folded in by the builder.
export interface SandboxPolicy {
  rwDirs: string[]; // writable directories: workspace, session, agent, memory
  rwFiles?: string[]; // writable files/sockets/devices (defaults += device nodes)
  roDirs?: string[]; // read-only directories that may be listed (defaults += /etc/ssl)
  roFiles?: string[]; // read-only files (defaults += /etc DNS/nss files)
  rx?: string[]; // read+execute parents (defaults += /nix/store)
  connectPorts?: number[]; // egress TCP ports the child may dial (credential proxy and/or local llama-swap); empty = no egress
  abi?: number; // highest requested Landlock ABI (best-effort below it); default 6
  scope?: ("signal" | "abstract_unix_socket")[]; // IPC scoping; default both
}

// Emit the landlockconfig document (JSON-serialisable) for one session. Pure.
// `abi: 6` + landlockconfig's best-effort modes mean an older kernel keeps the
// FS allowlist and drops netPort/scoped rather than failing.
export function buildLandlockPolicy(p: SandboxPolicy): Record<string, unknown> {
  const abi = p.abi ?? 6;
  const scope = p.scope ?? ["signal", "abstract_unix_socket"];
  const rx = p.rx ?? LANDLOCK_RX_PARENTS;
  const rwFiles = [...(p.rwFiles ?? []), ...LANDLOCK_DEV_FILES];
  const roDirs = [...(p.roDirs ?? []), ...LANDLOCK_ETC_RO_DIRS];
  const roFiles = [...(p.roFiles ?? []), ...LANDLOCK_ETC_RO_FILES];

  // Each entry pairs an access-right set with the paths it applies to; empty
  // buckets are dropped so the document carries no vacuous rules.
  const rules: [string[], string[]][] = [
    [["abi.read_write"], p.rwDirs],
    [["read_file", "write_file"], rwFiles],
    [["abi.read_execute"], rx],
    [["read_file", "read_dir"], roDirs],
    [["read_file"], roFiles],
  ];
  const pathBeneath = rules
    .filter(([, parent]) => parent.length > 0)
    .map(([allowedAccess, parent]) => ({ allowedAccess, parent }));

  const doc: Record<string, unknown> = {
    abi,
    ruleset: scope.length > 0 ? [{ scoped: scope }] : [],
    pathBeneath,
  };
  // Egress is locked to the model endpoint port(s): the credential proxy (so the
  // openrouter key never enters the sandbox) and/or the loopback llama-swap port
  // for the local provider. bind is never allowed (the runtime never listens).
  // Port-granular, not address-granular (§5.2).
  if (p.connectPorts && p.connectPorts.length > 0) {
    doc.netPort = [{ allowedAccess: ["connect_tcp"], port: p.connectPorts }];
  }
  return doc;
}

export interface LandlockUnitConfig {
  systemdRun: string; // path to systemd-run (or a stub, in tests)
  landlockExec: string; // path to pi-landlock-exec
  policyPath: string; // the per-session landlockconfig file the launcher reads
  unitName: string; // --unit= name, for inspection/teardown
  workdir: string; // pi's cwd (the session workspace)
  memoryHigh: string; // MemoryHigh= for the unit
  env: Record<string, string>; // --setenv entries (the unit gets a fresh env)
}

// The kernel/seccomp hardening carried on the Landlock session unit. No
// PrivateUsers/PrivateTmp/PrivateDevices/ProtectHome/TemporaryFileSystem/
// BindPaths — Landlock denies non-granted paths directly, so nothing is hidden
// then bound back, and there is no userns. RestrictAddressFamilies pins the
// socket families; RestrictNamespaces blocks new namespaces.
function landlockHardeningProps(memoryHigh: string): string[] {
  return [
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
    "--property=RestrictAddressFamilies=AF_UNIX AF_INET",
    "--property=SystemCallArchitectures=native",
    `--property=MemoryHigh=${memoryHigh}`,
  ];
}

// argv that runs `<childArgv>` (the pi rpc child) inside the per-session
// Landlock unit. systemd-run's command (after its own `--`) is the launcher,
// which applies the policy and then execs the child after a SECOND `--`:
//   systemd-run … -- pi-landlock-exec --json <policy> -- pi --mode rpc …
// `--pipe --wait` keep the unit's stdio bound to the supervisor's rpc driver.
export function buildLandlockUnitArgv(
  c: LandlockUnitConfig,
  childArgv: string[],
): string[] {
  return [
    c.systemdRun,
    "--pipe",
    "--quiet",
    "--collect",
    "--wait",
    "--service-type=exec",
    `--unit=${c.unitName}`,
    `--working-directory=${c.workdir}`,
    ...Object.entries(c.env).map(([k, v]) => `--setenv=${k}=${v}`),
    ...landlockHardeningProps(c.memoryHigh),
    // seccomp (§5.4): @system-service baseline, then subtract the denylist.
    "--property=SystemCallFilter=@system-service",
    `--property=SystemCallFilter=~${LANDLOCK_DENY_SYSCALLS.join(" ")}`,
    // Blocked calls return EPERM instead of SIGSYS-killing the process: node's
    // libuv probes io_uring_setup at startup and falls back to epoll on EPERM,
    // where a kill would core-dump the whole runtime. The denylist still bars
    // every call — this only changes the failure from fatal to a clean errno.
    "--property=SystemCallErrorNumber=EPERM",
    "--",
    c.landlockExec,
    "--json",
    c.policyPath,
    "--",
    ...childArgv,
  ];
}
