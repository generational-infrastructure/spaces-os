import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { isSessionId, SessionStore } from "./session-store";

const ID = "ab111111-2222-3333-4444-55555555cdef";
const META = { provider: "local", model: "m1", name: "chat one" };

let base: string;
let store: SessionStore;

beforeEach(() => {
  base = mkdtempSync(join(tmpdir(), "session-store-"));
  store = new SessionStore(base);
});
afterEach(() => {
  rmSync(base, { recursive: true, force: true });
});

// ---- id validation (path-traversal guard) ----------------------------------

test("isSessionId accepts only our minted uuid shape", () => {
  expect(isSessionId(ID)).toBe(true);
  expect(isSessionId("")).toBe(false);
  expect(isSessionId("../../etc/passwd")).toBe(false);
  expect(isSessionId(`${ID}/nested`)).toBe(false);
  expect(isSessionId(ID.toUpperCase())).toBe(false);
});

// ---- layout ----------------------------------------------------------------

test("the store nests every per-session path under its base dir", () => {
  expect(store.sessionDirOf(ID)).toBe(`${base}/sessions/${ID}`);
  expect(store.workdirOf(ID)).toBe(`${base}/workspaces/${ID}`);
  expect(store.agentDirOf(ID)).toBe(`${base}/sessions/${ID}/agent`);
  expect(store.tmpDirOf(ID)).toBe(`${base}/sessions/${ID}/tmp`);
  expect(store.metaPathOf(ID)).toBe(`${base}/sessions/${ID}.meta.json`);
});

// ---- create → meta → cold-list → delete round-trip ---------------------------

test("create lays out the dirs and persists meta that reads back", () => {
  store.create(ID, META);
  expect(existsSync(store.sessionDirOf(ID))).toBe(true);
  expect(existsSync(store.workdirOf(ID))).toBe(true);
  expect(store.readMeta(ID)).toEqual(META);
});

test("a created session is cold-listed with a real updated timestamp", () => {
  store.create(ID, META);
  expect(store.coldSessionIds()).toEqual([ID]);
  expect(store.coldUpdatedMs(ID)).toBeGreaterThan(0);
});

test("cold listing ignores sidecars whose name is not a session id", () => {
  store.create(ID, META);
  writeFileSync(`${base}/sessions/evil.meta.json`, "{}");
  writeFileSync(`${base}/sessions/notes.txt`, "");
  expect(store.coldSessionIds()).toEqual([ID]);
});

test("delete leaves nothing behind and is idempotent", () => {
  store.create(ID, META);
  store.delete(ID);
  expect(existsSync(store.sessionDirOf(ID))).toBe(false);
  expect(existsSync(store.metaPathOf(ID))).toBe(false);
  expect(existsSync(store.workdirOf(ID))).toBe(false);
  expect(readdirSync(`${base}/sessions`)).toEqual([]);
  expect(store.coldSessionIds()).toEqual([]);
  store.delete(ID); // missing id: no throw
});

// ---- meta edge cases ---------------------------------------------------------

test("readMeta tolerates missing or malformed sidecars", () => {
  expect(store.readMeta(ID)).toBeUndefined();
  writeFileSync(store.metaPathOf(ID), "not json");
  expect(store.readMeta(ID)).toBeUndefined();
  writeFileSync(store.metaPathOf(ID), JSON.stringify({ provider: "local" }));
  expect(store.readMeta(ID)).toBeUndefined(); // model missing
  writeFileSync(
    store.metaPathOf(ID),
    JSON.stringify({ provider: "local", model: "m1" }),
  );
  expect(store.readMeta(ID)).toEqual({ provider: "local", model: "m1", name: "" });
});

test("ensureWorkdir recreates a workspace dropped from disk", () => {
  store.ensureWorkdir(ID);
  expect(existsSync(store.workdirOf(ID))).toBe(true);
  store.ensureWorkdir(ID); // existing: no throw
});

test("coldUpdatedMs is 0 for a session with no dir on disk", () => {
  expect(store.coldUpdatedMs(ID)).toBe(0);
});
