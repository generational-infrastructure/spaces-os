import { expect, test } from "bun:test";

import {
  type LandlockUnitConfig,
  type SandboxPolicy,
  LANDLOCK_DENY_SYSCALLS,
  buildLandlockPolicy,
  buildLandlockUnitArgv,
} from "./sandbox";

const CHILD = ["pi", "--mode", "rpc", "--session-id", "abc123"];

// ---- Landlock launcher path (design §5/§6) --------------------------------

const policyInput: SandboxPolicy = {
  rwDirs: [
    "/var/lib/pi-sessiond/workspaces/abc123",
    "/var/lib/pi-sessiond/sessions/abc123",
    "/var/lib/pi-sessiond/pi-agent",
  ],
  rwFiles: ["/run/user/1000/skill-config.sock"],
  roDirs: ["/run/user/1000/skills-defs"],
  connectPorts: [41234],
};

test("the landlockconfig policy is deny-by-default with fs/net/scope grants", () => {
  const doc = buildLandlockPolicy(policyInput) as {
    abi: number;
    ruleset: { scoped: string[] }[];
    pathBeneath: { allowedAccess: string[]; parent: string[] }[];
    netPort?: { allowedAccess: string[]; port: number[] }[];
  };

  expect(doc.abi).toBe(6);
  // ABI-6 IPC scoping: the cross-session/other-process wall (replaces uid).
  expect(doc.ruleset).toEqual([{ scoped: ["signal", "abstract_unix_socket"] }]);

  // Writable directories get the full read_write group — parents are exactly
  // the session dirs, no files mixed in (so the ruleset stays fully enforced).
  const rwDirs = doc.pathBeneath.find((r) =>
    r.allowedAccess.includes("abi.read_write"),
  );
  expect(rwDirs?.parent).toEqual(policyInput.rwDirs);

  // Files/sockets/devices take file rights only — never read_dir / make_*.
  const rwFiles = doc.pathBeneath.find((r) =>
    r.allowedAccess.includes("write_file"),
  );
  expect(rwFiles?.allowedAccess).toEqual(["read_file", "write_file"]);
  expect(rwFiles?.parent).toEqual(
    expect.arrayContaining([
      "/run/user/1000/skill-config.sock",
      "/dev/null",
      "/dev/urandom",
    ]),
  );

  const rx = doc.pathBeneath.find((r) =>
    r.allowedAccess.includes("abi.read_execute"),
  );
  expect(rx?.parent).toContain("/nix/store");

  // Read-only directories may be listed (read_dir); read-only files may not.
  const roDirs = doc.pathBeneath.find((r) =>
    r.allowedAccess.includes("read_dir"),
  );
  expect(roDirs?.parent).toEqual(
    expect.arrayContaining(["/run/user/1000/skills-defs", "/etc/ssl"]),
  );
  const roFiles = doc.pathBeneath.find(
    (r) => r.allowedAccess.length === 1 && r.allowedAccess[0] === "read_file",
  );
  expect(roFiles?.parent).toEqual(
    expect.arrayContaining(["/etc/resolv.conf", "/etc/passwd"]),
  );

  // ABI-4 egress: connect-only to the configured model endpoint port(s).
  expect(doc.netPort).toEqual([
    { allowedAccess: ["connect_tcp"], port: [41234] },
  ]);
});

test("the policy excludes the home and sibling sessions (leaf-scoped)", () => {
  const doc = buildLandlockPolicy(policyInput) as {
    pathBeneath: { parent: string[] }[];
  };
  const granted = doc.pathBeneath.flatMap((r) => r.parent);
  // Nothing broad: not $HOME, not another session, not the whole state root.
  expect(granted).not.toContain("/home/amy");
  expect(granted).not.toContain("/var/lib/pi-sessiond/workspaces/other");
  expect(granted).not.toContain("/var/lib/pi-sessiond");
});

test("multiple connect ports collapse into one connect_tcp rule", () => {
  // The child may reach both the credential proxy and the local llama-swap
  // endpoint; both ports ride a single netPort entry.
  const doc = buildLandlockPolicy({
    rwDirs: ["/x"],
    connectPorts: [41234, 8012],
  }) as { netPort?: { allowedAccess: string[]; port: number[] }[] };
  expect(doc.netPort).toEqual([
    { allowedAccess: ["connect_tcp"], port: [41234, 8012] },
  ]);
});

test("no connect ports means no egress rule", () => {
  const doc = buildLandlockPolicy({ rwDirs: ["/x"] }) as {
    netPort?: unknown;
  };
  expect(doc.netPort).toBeUndefined();
});

const landlockUnit: LandlockUnitConfig = {
  systemdRun: "/run/wrappers/systemd-run",
  landlockExec: "/nix/store/zzz-pi-landlock-exec/bin/pi-landlock-exec",
  policyPath: "/var/lib/pi-sessiond/sessions/abc123/landlock.json",
  unitName: "pi-session-abc123.service",
  workdir: "/var/lib/pi-sessiond/workspaces/abc123",
  memoryHigh: "4G",
  env: { PI_CODING_AGENT_DIR: "/var/lib/pi-sessiond/pi-agent" },
};

test("the landlock unit runs the launcher then the child, no userns machinery", () => {
  const argv = buildLandlockUnitArgv(landlockUnit, CHILD);

  expect(argv[0]).toBe(landlockUnit.systemdRun);
  expect(argv).toContain("--pipe");
  expect(argv).toContain("--wait");
  expect(argv).toContain(`--unit=${landlockUnit.unitName}`);
  expect(argv).toContain(`--working-directory=${landlockUnit.workdir}`);
  expect(argv).toContain(
    "--setenv=PI_CODING_AGENT_DIR=/var/lib/pi-sessiond/pi-agent",
  );

  // None of the userns / filesystem-hiding machinery: Landlock denies directly.
  expect(argv).not.toContain("--property=PrivateUsers=managed");
  expect(argv.some((a) => a.startsWith("--property=ProtectHome"))).toBe(false);
  expect(argv.some((a) => a.startsWith("--property=TemporaryFileSystem"))).toBe(
    false,
  );
  expect(argv.some((a) => a.startsWith("--property=BindPaths"))).toBe(false);

  // seccomp denylist on the unit (§5.4): allow baseline, then subtract.
  expect(argv).toContain("--property=SystemCallFilter=@system-service");
  expect(argv).toContain(
    `--property=SystemCallFilter=~${LANDLOCK_DENY_SYSCALLS.join(" ")}`,
  );
  // Blocked syscalls fail soft (EPERM), not SIGSYS — see §5.4 (libuv io_uring).
  expect(argv).toContain("--property=SystemCallErrorNumber=EPERM");

  // systemd-run -- pi-landlock-exec --json <policy> -- <child>
  const sep = argv.indexOf("--");
  expect(argv[sep + 1]).toBe(landlockUnit.landlockExec);
  expect(argv[sep + 2]).toBe("--json");
  expect(argv[sep + 3]).toBe(landlockUnit.policyPath);
  expect(argv[sep + 4]).toBe("--");
  expect(argv.slice(sep + 5)).toEqual(CHILD);
});
