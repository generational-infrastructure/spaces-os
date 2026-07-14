import { expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadEnabled, sessionSharedDirs } from "./integrations";

const root = mkdtempSync(join(tmpdir(), "integrations-test-"));

function enabledFile(name: string, content: unknown): string {
  const path = join(root, `${name}.json`);
  writeFileSync(
    path,
    typeof content === "string" ? content : JSON.stringify(content),
  );
  return path;
}

test("loadEnabled returns only the enabled integration names", () => {
  const path = enabledFile("enabled", {
    integrations: {
      github: { enabled: true },
      signal: { enabled: false },
      mail: { enabled: true },
    },
  });
  expect(loadEnabled(path).sort()).toEqual(["github", "mail"]);
});

test("loadEnabled skips names that are not plain idents", () => {
  const path = enabledFile("bad-names", {
    integrations: { "../evil": { enabled: true }, ok: { enabled: true } },
  });
  expect(loadEnabled(path)).toEqual(["ok"]);
});

test("loadEnabled yields nothing for a missing or malformed file", () => {
  expect(loadEnabled(join(root, "no-such.json"))).toEqual([]);
  expect(loadEnabled(enabledFile("broken", "{oops"))).toEqual([]);
});

test("sessionSharedDirs grants <base>/<name> per enabled integration", () => {
  const path = enabledFile("shared", {
    integrations: { github: { enabled: true }, mail: { enabled: true } },
  });
  expect(sessionSharedDirs(path, "/run/share").sort()).toEqual([
    "/run/share/github",
    "/run/share/mail",
  ]);
});

test("sessionSharedDirs is empty without a base, path, or integrations", () => {
  const path = enabledFile("shared2", {
    integrations: { github: { enabled: true } },
  });
  expect(sessionSharedDirs(path, "")).toEqual([]); // no base
  expect(sessionSharedDirs("", "/run/share")).toEqual([]); // no path
  expect(
    sessionSharedDirs(enabledFile("none", { integrations: {} }), "/run/share"),
  ).toEqual([]); // no enabled integrations
});
