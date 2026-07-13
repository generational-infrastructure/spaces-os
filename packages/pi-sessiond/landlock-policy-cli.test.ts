import { expect, test } from "bun:test";

import { buildLandlockPolicy } from "./sandbox";
import {
  type IntegrationPolicySpec,
  lowerIntegrationPolicy,
  resolveFromEnv,
} from "./landlock-policy-cli";

// The static spec lib.nix emits for the GitHub integration: HTTPS egress only.
const githubSpec: IntegrationPolicySpec = {
  connectPorts: [443],
  abi: 6,
  scope: ["signal", "abstract_unix_socket"],
};

// What systemd hands the unit at start: an absolute StateDirectory (rw) and the
// decrypted credentials mount (ro). Sample values stand in for the per-user
// paths that only exist at unit start.
const resolved = {
  stateDirs: ["/home/alice/.local/state/spaces-integration-github"],
  credDirs: ["/run/user/1000/credentials/spaces-integration-github"],
};

test("lowerIntegrationPolicy: writable surface is StateDirectory + private tmpfs", () => {
  const p = lowerIntegrationPolicy(githubSpec, resolved);
  expect(p.rwDirs).toEqual([
    "/home/alice/.local/state/spaces-integration-github",
    "/tmp",
    "/var/tmp",
  ]);
});

test("lowerIntegrationPolicy: credentials mount is read-only, ports pass through", () => {
  const p = lowerIntegrationPolicy(githubSpec, resolved);
  expect(p.roDirs).toEqual([
    "/run/user/1000/credentials/spaces-integration-github",
  ]);
  expect(p.connectPorts).toEqual([443]);
  expect(p.abi).toBe(6);
  expect(p.scope).toEqual(["signal", "abstract_unix_socket"]);
});

test("lowerIntegrationPolicy: a shared exchange dir joins the writable surface", () => {
  const p = lowerIntegrationPolicy(githubSpec, {
    ...resolved,
    sharedDirs: ["/run/user/1000/spaces-exchange/github-alice"],
  });
  expect(p.rwDirs).toEqual([
    "/home/alice/.local/state/spaces-integration-github",
    "/tmp",
    "/var/tmp",
    "/run/user/1000/spaces-exchange/github-alice",
  ]);
});

test("lowerIntegrationPolicy: the unit-private tmpfs joins the writable surface", () => {
  // Every integration unit runs with PrivateTmp=disconnected (lib.nix), so
  // /tmp and /var/tmp are a private per-unit tmpfs — but Landlock is
  // deny-by-default and landlock-exec applies the policy INSIDE the mount
  // namespace, so the private tmpfs still needs an explicit rw grant or
  // tempfile.mkdtemp in the server dies with "No usable temporary directory".
  const p = lowerIntegrationPolicy(githubSpec, resolved);
  expect(p.rwDirs).toContain("/tmp");
  expect(p.rwDirs).toContain("/var/tmp");
});

test("resolveFromEnv: colon-lists split, absent vars yield empty", () => {
  expect(resolveFromEnv({ STATE_DIRECTORY: "/a:/b" }).stateDirs).toEqual([
    "/a",
    "/b",
  ]);
  expect(resolveFromEnv({}).credDirs).toEqual([]);
  expect(
    resolveFromEnv({ SPACES_INTEGRATION_SHARED_DIR: "" }).sharedDirs,
  ).toEqual([]);
});

test("end-to-end: deny-by-default doc grants exactly StateDir(rw) + cred(ro) + 443", () => {
  const doc = buildLandlockPolicy(
    lowerIntegrationPolicy(githubSpec, resolved),
  ) as {
    abi: number;
    ruleset: { scoped?: string[]; handledAccessNet?: string[] }[];
    pathBeneath: { allowedAccess: string[]; parent: string[] }[];
    netPort?: { allowedAccess: string[]; port: number[] }[];
  };

  expect(doc.abi).toBe(6);
  expect(doc.ruleset).toEqual([
    {
      scoped: ["signal", "abstract_unix_socket"],
      handledAccessNet: ["bind_tcp"],
    },
  ]);

  // Exactly one read_write bucket: the StateDirectory + the unit-private
  // tmpfs (PrivateTmp=disconnected — never the host /tmp).
  const rw = doc.pathBeneath.filter((r) =>
    r.allowedAccess.includes("abi.read_write"),
  );
  expect(rw).toHaveLength(1);
  expect(rw[0]!.parent).toEqual([
    "/home/alice/.local/state/spaces-integration-github",
    "/tmp",
    "/var/tmp",
  ]);

  // The credentials mount is granted read-only (alongside the /etc TLS dirs the
  // builder folds in), never read_write.
  const credRo = doc.pathBeneath.find(
    (r) =>
      r.parent.includes(
        "/run/user/1000/credentials/spaces-integration-github",
      ) && r.allowedAccess.includes("read_file"),
  );
  expect(credRo).toBeDefined();
  expect(credRo!.allowedAccess).not.toContain("write_file");

  // Egress is locked to 443; nothing else.
  expect(doc.netPort).toEqual([
    { allowedAccess: ["connect_tcp"], port: [443] },
  ]);

  // The agent's home and arbitrary paths are never granted.
  const allParents = doc.pathBeneath.flatMap((r) => r.parent);
  expect(allParents).not.toContain("/home/alice");
  expect(allParents).not.toContain("/home/alice/.local/state");
});

test("lowerIntegrationPolicy: bindPorts fold through into a bind_tcp rule", () => {
  // A mail-style integration that listens on a local IMAP+SMTP bridge declares
  // bind ports; they lower into a bind_tcp netPort entry, distinct from egress.
  const spec: IntegrationPolicySpec = {
    connectPorts: [443],
    bindPorts: [1143, 1025],
    abi: 6,
    scope: ["signal", "abstract_unix_socket"],
  };
  const p = lowerIntegrationPolicy(spec, resolved);
  expect(p.bindPorts).toEqual([1143, 1025]);
  const doc = buildLandlockPolicy(p) as {
    netPort?: { allowedAccess: string[]; port: number[] }[];
  };
  expect(doc.netPort).toEqual([
    { allowedAccess: ["connect_tcp"], port: [443] },
    { allowedAccess: ["bind_tcp"], port: [1143, 1025] },
  ]);
});

test("lowerIntegrationPolicy: absent bindPorts grants no bind but keeps it handled", () => {
  // Deny-by-default: no bind grant, no bind netPort rule, yet bind_tcp stays in
  // the handled set so any unlisted bind is refused.
  const p = lowerIntegrationPolicy(githubSpec, resolved);
  expect(p.bindPorts).toEqual([]);
  const doc = buildLandlockPolicy(p) as {
    ruleset: { handledAccessNet?: string[] }[];
    netPort?: { allowedAccess: string[]; port: number[] }[];
  };
  expect(doc.ruleset[0]!.handledAccessNet).toEqual(["bind_tcp"]);
  expect(doc.netPort).toEqual([
    { allowedAccess: ["connect_tcp"], port: [443] },
  ]);
});

// A signal-style integration: a rw socket dir + an ro attachments dir folded
// into the sandbox surfaces via `extraPaths`. The state dir stays the only
// implicit writable; the ro grant must never leak into the writable set.
const signalResolved = {
  stateDirs: ["/home/alice/.local/state/spaces-integration-signal"],
  credDirs: [],
  runtimeDir: "/run/user/1000",
  homeDir: "/home/alice",
};

test("lowerIntegrationPolicy: extraPaths route ro→roDirs, rw→rwDirs", () => {
  const spec: IntegrationPolicySpec = {
    abi: 6,
    scope: ["signal", "abstract_unix_socket"],
    extraPaths: [
      { source: "/run/user/1000/signal-cli", mode: "rw" },
      { source: "/home/x/.local/share/signal-cli/attachments", mode: "ro" },
    ],
  };
  const p = lowerIntegrationPolicy(spec, signalResolved);
  expect(p.rwDirs).toContain("/run/user/1000/signal-cli");
  expect(p.roDirs).toContain("/home/x/.local/share/signal-cli/attachments");
  // StateDirectory stays writable; the ro extra never joins the rw set.
  expect(p.rwDirs).toContain(
    "/home/alice/.local/state/spaces-integration-signal",
  );
  expect(p.rwDirs).not.toContain("/home/x/.local/share/signal-cli/attachments");
});

test("lowerIntegrationPolicy: %t/%h in extraPaths expand from the unit env", () => {
  // lib.nix bakes the spec into a store file, so systemd never expands
  // specifiers inside its CONTENTS — the CLI resolves %t/%h from the env itself.
  const spec: IntegrationPolicySpec = {
    extraPaths: [
      { source: "%t/signal-cli", mode: "rw" },
      { source: "%h/.local/share/signal-cli/attachments", mode: "ro" },
    ],
  };
  const p = lowerIntegrationPolicy(spec, signalResolved);
  expect(p.rwDirs).toContain("/run/user/1000/signal-cli");
  expect(p.roDirs).toContain("/home/alice/.local/share/signal-cli/attachments");
});

test("lowerIntegrationPolicy: an unresolvable specifier fails closed", () => {
  const spec: IntegrationPolicySpec = {
    extraPaths: [{ source: "%t/signal-cli", mode: "rw" }],
  };
  expect(() =>
    lowerIntegrationPolicy(spec, { stateDirs: [], credDirs: [] }),
  ).toThrow(/XDG_RUNTIME_DIR/);
});

test("resolveFromEnv: %t/%h sources come from XDG_RUNTIME_DIR/HOME", () => {
  const r = resolveFromEnv({
    XDG_RUNTIME_DIR: "/run/user/1000",
    HOME: "/home/bob",
  });
  expect(r.runtimeDir).toBe("/run/user/1000");
  expect(r.homeDir).toBe("/home/bob");
});
