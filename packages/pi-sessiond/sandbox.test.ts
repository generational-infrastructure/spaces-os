import { expect, test } from "bun:test";

import { type BashSandboxConfig, buildBashSandboxArgv } from "./sandbox";

const base: BashSandboxConfig = {
  systemdRun: "/run/wrappers/systemd-run",
  workdir: "/var/lib/pi-sessiond/workspaces/abc123",
  agentDir: "/var/lib/pi-sessiond/pi-agent",
  memoryHigh: "4G",
  trusted: false,
  extraBinds: ["/var/lib/pi-sessiond/sessions/abc123"],
};
const CMD = "echo hi && ls";

test("an untrusted bash command is wrapped sandboxed via systemd-run", () => {
  const argv = buildBashSandboxArgv(base, CMD);

  // Wrapped in a piped, collected, waited transient unit.
  expect(argv[0]).toBe(base.systemdRun);
  expect(argv).toContain("--pipe");
  expect(argv).toContain("--collect");
  expect(argv).toContain("--wait");
  expect(argv).toContain(`--working-directory=${base.workdir}`);

  // Filesystem narrowing: hide the real home, bind the workdir + agent dir back.
  expect(argv).toContain("--property=ProtectHome=tmpfs");
  expect(argv).toContain(`--property=BindPaths=${base.workdir}:${base.workdir}`);
  expect(argv).toContain(`--property=BindPaths=${base.agentDir}:${base.agentDir}`);
  // extraBinds (the session dir) are bound rw too.
  expect(argv).toContain(
    "--property=BindPaths=/var/lib/pi-sessiond/sessions/abc123:/var/lib/pi-sessiond/sessions/abc123",
  );

  // Kernel / namespace protection set.
  for (const prop of [
    "--property=PrivateTmp=true",
    "--property=PrivateDevices=true",
    "--property=ProtectProc=invisible",
    "--property=NoNewPrivileges=true",
    "--property=RestrictSUIDSGID=true",
    "--property=RestrictNamespaces=true",
    "--property=SystemCallArchitectures=native",
    `--property=MemoryHigh=${base.memoryHigh}`,
  ]) {
    expect(argv).toContain(prop);
  }

  // The command is the unit's payload after `--`, passed as a single argv
  // element to `bash -c` so there is no nested-shell quoting to get wrong.
  const sep = argv.indexOf("--");
  expect(sep).toBeGreaterThan(0);
  expect(argv.slice(sep + 1)).toEqual(["bash", "-c", CMD]);
});

test("a trusted command keeps protections but drops filesystem narrowing", () => {
  const argv = buildBashSandboxArgv({ ...base, trusted: true }, CMD);
  expect(argv).not.toContain("--property=ProtectHome=tmpfs");
  // The agent-dir bind is only added for untrusted (alongside ProtectHome).
  expect(argv).not.toContain(`--property=BindPaths=${base.agentDir}:${base.agentDir}`);
  // The non-filesystem protections still apply.
  expect(argv).toContain("--property=NoNewPrivileges=true");
  expect(argv).toContain("--property=RestrictNamespaces=true");
  // The workdir is still narrowed/bound.
  expect(argv).toContain(`--property=BindPaths=${base.workdir}:${base.workdir}`);
});

test("the command is preserved verbatim as a single argv element", () => {
  const tricky = `echo "a b" 'c'; rm -rf "$X"`;
  const argv = buildBashSandboxArgv(base, tricky);
  expect(argv[argv.length - 1]).toBe(tricky);
});
