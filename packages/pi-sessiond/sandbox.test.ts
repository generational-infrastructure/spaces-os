import { expect, test } from "bun:test";

import { buildSpawnCommand, type SpawnConfig } from "./sandbox";

const base: SpawnConfig = {
  systemdRun: "/run/wrappers/systemd-run",
  piBin: "/store/pi/bin/pi",
  sessionId: "abc123",
  sessionDir: "/var/lib/pi-sessiond/sessions/abc123",
  workdir: "/var/lib/pi-sessiond/workspaces/abc123",
  agentDir: "/var/lib/pi-sessiond/pi-agent",
  llmUrl: "http://127.0.0.1:8013",
  provider: "local",
  model: "mock-model",
  memoryHigh: "4G",
  path: "/run/current-system/sw/bin",
  trusted: false,
  continueSession: false,
};

test("an untrusted session is launched sandboxed via systemd-run", () => {
  const { argv } = buildSpawnCommand(base);

  // Wrapped in systemd-run with a piped, collected transient unit.
  expect(argv[0]).toBe(base.systemdRun);
  expect(argv).toContain("--pipe");
  expect(argv).toContain("--collect");

  // Filesystem narrowing.
  expect(argv).toContain("--property=ProtectHome=tmpfs");
  expect(argv).toContain(`--property=BindPaths=${base.workdir}:${base.workdir}`);
  expect(argv).toContain(`--property=BindPaths=${base.agentDir}:${base.agentDir}`);
  // Persisted session dir, bound rw so sandboxed pi can write session.jsonl.
  expect(argv).toContain(`--property=BindPaths=${base.sessionDir}:${base.sessionDir}`);
  expect(argv).not.toContain("--no-session");
  expect(argv).not.toContain("--continue");

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

  // pi's env is carried into the unit, and pi connects to the executor's LLM.
  expect(argv).toContain(`--setenv=LLAMA_SWAP_BASE_URL=${base.llmUrl}`);
  expect(argv).toContain(`--setenv=PI_CODING_AGENT_DIR=${base.agentDir}`);

  // pi itself is the unit's payload, after the `--` separator.
  const sep = argv.indexOf("--");
  expect(sep).toBeGreaterThan(0);
  expect(argv.slice(sep + 1)).toEqual([
    base.piBin,
    "--mode",
    "rpc",
    "--provider",
    "local",
    "--session-dir",
    base.sessionDir,
    "--offline",
    "--no-context-files",
    "--model",
    "mock-model",
  ]);
});

test("a trusted session keeps protections but drops ProtectHome", () => {
  const { argv } = buildSpawnCommand({ ...base, trusted: true });
  expect(argv).not.toContain("--property=ProtectHome=tmpfs");
  // The non-filesystem protections still apply.
  expect(argv).toContain("--property=NoNewPrivileges=true");
  expect(argv).toContain("--property=RestrictNamespaces=true");
});

test("model is omitted when unset", () => {
  const { argv } = buildSpawnCommand({ ...base, model: "" });
  expect(argv).not.toContain("--model");
});

test("a resumed session passes --continue to replay the committed jsonl", () => {
  const { argv } = buildSpawnCommand({ ...base, continueSession: true });
  expect(argv).toContain("--continue");
});
