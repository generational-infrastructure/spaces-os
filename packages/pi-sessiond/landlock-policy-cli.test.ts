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

test("lowerIntegrationPolicy: StateDirectory is the only writable surface", () => {
  const p = lowerIntegrationPolicy(githubSpec, resolved);
  expect(p.rwDirs).toEqual([
    "/home/alice/.local/state/spaces-integration-github",
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
    "/run/user/1000/spaces-exchange/github-alice",
  ]);
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
    ruleset: { scoped: string[] }[];
    pathBeneath: { allowedAccess: string[]; parent: string[] }[];
    netPort?: { allowedAccess: string[]; port: number[] }[];
  };

  expect(doc.abi).toBe(6);
  expect(doc.ruleset).toEqual([{ scoped: ["signal", "abstract_unix_socket"] }]);

  // Exactly one read_write bucket, and it is exactly the StateDirectory.
  const rw = doc.pathBeneath.filter((r) =>
    r.allowedAccess.includes("abi.read_write"),
  );
  expect(rw).toHaveLength(1);
  expect(rw[0]!.parent).toEqual([
    "/home/alice/.local/state/spaces-integration-github",
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
