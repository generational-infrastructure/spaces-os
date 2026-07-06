import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import type { RpcFrame } from "./rpc-driver";
import { SessionStore } from "./session-store";
import {
  type DriverCallbacks,
  type Session,
  type SessionSpec,
  isEvictable,
  SessionSupervisor,
} from "./session-supervisor";

// Fake client handles: the supervisor never touches them beyond set membership.
type Client = string;
type Sess = Session<Client>;

interface Spawn {
  spec: SessionSpec;
  callbacks: DriverCallbacks;
  stopped: boolean;
}

let base: string;
let store: SessionStore;
let spawns: Spawn[];
let sessionsChanged: number;
let events: { session: Sess; frame: RpcFrame }[];
let sideChannels: { session: Sess; frame: RpcFrame }[];

function makeSupervisor(
  opts: { maxLive?: number; idleTimeoutMs?: number } = {},
): SessionSupervisor<Client> {
  return new SessionSupervisor<Client>({
    store,
    executorId: "exec-1",
    maxLive: opts.maxLive ?? 0,
    idleTimeoutMs: opts.idleTimeoutMs ?? 0,
    createDriver: (spec, callbacks) => {
      const spawn: Spawn = { spec, callbacks, stopped: false };
      spawns.push(spawn);
      return {
        request: async () => ({ type: "response", success: true }),
        send: () => {},
        stop: async () => {
          spawn.stopped = true;
        },
      };
    },
    onEvent: (session, frame) => events.push({ session, frame }),
    onSideChannel: (session, frame) => sideChannels.push({ session, frame }),
    onSessionsChanged: () => {
      sessionsChanged += 1;
    },
  });
}

beforeEach(() => {
  base = mkdtempSync(join(tmpdir(), "session-supervisor-"));
  store = new SessionStore(base);
  spawns = [];
  sessionsChanged = 0;
  events = [];
  sideChannels = [];
});
afterEach(() => {
  rmSync(base, { recursive: true, force: true });
});

// ---- create / resume ---------------------------------------------------------

test("create mints a session, persists its meta, and spawns one driver", () => {
  const sup = makeSupervisor();
  const session = sup.create("local", "m1", "chat");
  expect(sup.get(session.id)).toBe(session);
  expect(store.readMeta(session.id)).toEqual({
    provider: "local",
    model: "m1",
    name: "chat",
  });
  expect(spawns.map((s) => s.spec)).toEqual([
    { id: session.id, name: "chat", provider: "local", model: "m1" },
  ]);
});

test("resume respawns a cold session from its meta; unknown ids resume nothing", () => {
  const sup = makeSupervisor();
  const { id } = sup.create("local", "m1", "chat");
  sup.gc(sup.get(id) as Sess);
  expect(sup.get(id)).toBeUndefined();

  const resumed = sup.resume(id);
  expect(resumed?.id).toBe(id);
  expect(spawns[1]?.spec).toEqual({
    id,
    name: "chat",
    provider: "local",
    model: "m1",
  });
  // Resuming a live session is idempotent — no third spawn.
  expect(sup.resume(id)).toBe(resumed as Sess);
  expect(spawns).toHaveLength(2);

  expect(sup.resume("de111111-2222-3333-4444-55555555adad")).toBeUndefined();
});

// ---- driver callback wiring ----------------------------------------------------

test("agent_start/agent_end flip busy before the event reaches the transport", () => {
  const sup = makeSupervisor();
  const session = sup.create("local", "m1", "");
  const cb = spawns[0]!.callbacks;

  cb.onEvent({ type: "agent_start" });
  expect(session.busy).toBe(true);
  cb.onEvent({ type: "agent_end" });
  expect(session.busy).toBe(false);
  expect(events.map((e) => e.frame.type)).toEqual(["agent_start", "agent_end"]);
});

test("extension_ui frames route to the side-channel hook with their session", () => {
  const sup = makeSupervisor();
  const session = sup.create("local", "m1", "");
  spawns[0]!.callbacks.onExtensionUI({
    type: "extension_ui_request",
    id: "u1",
  });
  expect(sideChannels).toEqual([
    { session, frame: { type: "extension_ui_request", id: "u1" } },
  ]);
});

test("a child exit clears busy and every parked prompt (missed-unpark)", () => {
  const sup = makeSupervisor();
  const session = sup.create("local", "m1", "");
  const cb = spawns[0]!.callbacks;
  cb.onEvent({ type: "agent_start" });
  session.ledger.raise("u1", "confirm", () => {});
  expect(isEvictable(session)).toBe(false);

  cb.onExit();
  expect(session.busy).toBe(false);
  expect(session.ledger.parked).toBe(false);
  expect(isEvictable(session)).toBe(true);
});

// ---- isEvictable ---------------------------------------------------------------

test("attached, busy, or parked sessions are never evictable", () => {
  const sup = makeSupervisor();
  const session = sup.create("local", "m1", "");
  expect(isEvictable(session)).toBe(true);

  session.subscribers.add("ws-1");
  expect(isEvictable(session)).toBe(false);
  session.subscribers.delete("ws-1");

  session.busy = true;
  expect(isEvictable(session)).toBe(false);
  session.busy = false;

  session.ledger.raise("u1", "confirm", () => {});
  expect(isEvictable(session)).toBe(false);
});

// ---- idle GC -------------------------------------------------------------------

test("gcIdle disposes only evictable sessions idle past the timeout", () => {
  const sup = makeSupervisor({ idleTimeoutMs: 1000 });
  const stale = sup.create("local", "m1", "stale");
  const fresh = sup.create("local", "m1", "fresh");
  const attached = sup.create("local", "m1", "attached");
  attached.subscribers.add("ws-1");

  stale.lastActivity = Date.now() - 2000;
  attached.lastActivity = Date.now() - 2000;
  sup.gcIdle();

  expect(sup.get(stale.id)).toBeUndefined();
  expect(spawns[0]!.stopped).toBe(true);
  expect(sessionsChanged).toBe(1); // one list-shaping change: the disposal
  expect(sup.get(fresh.id)).toBeDefined();
  expect(sup.get(attached.id)).toBeDefined();
  // Cold, not deleted: the meta survives for the next attach.
  expect(store.readMeta(stale.id)).toBeDefined();
});

test("gcIdle with the timeout disabled never disposes", () => {
  const sup = makeSupervisor({ idleTimeoutMs: 0 });
  const session = sup.create("local", "m1", "");
  session.lastActivity = 0;
  sup.gcIdle();
  expect(sup.get(session.id)).toBeDefined();
});

// ---- resident ceiling ------------------------------------------------------------

test("create evicts the least-recently-active evictable session at the ceiling", () => {
  const sup = makeSupervisor({ maxLive: 2 });
  const oldest = sup.create("local", "m1", "oldest");
  const newer = sup.create("local", "m1", "newer");
  oldest.lastActivity = 1;
  newer.lastActivity = 2;

  const third = sup.create("local", "m1", "third");
  expect(sup.get(oldest.id)).toBeUndefined();
  expect(spawns[0]!.stopped).toBe(true);
  expect(sup.get(newer.id)).toBeDefined();
  expect(sup.get(third.id)).toBeDefined();
});

test("the ceiling never evicts busy sessions — it overshoots instead", () => {
  const sup = makeSupervisor({ maxLive: 1 });
  const busy = sup.create("local", "m1", "busy");
  busy.busy = true;
  const second = sup.create("local", "m1", "second");
  expect(sup.get(busy.id)).toBeDefined();
  expect(sup.get(second.id)).toBeDefined();
});

// ---- delete ------------------------------------------------------------------------

test("delete stops the live child and wipes the disk", async () => {
  const sup = makeSupervisor();
  const session = sup.create("local", "m1", "doomed");
  await sup.delete(session.id);
  expect(sup.get(session.id)).toBeUndefined();
  expect(spawns[0]!.stopped).toBe(true);
  expect(store.readMeta(session.id)).toBeUndefined();
  expect(store.coldSessionIds()).toEqual([]);
});

// ---- list ---------------------------------------------------------------------------

test("list stamps live states and folds in cold sidecars", () => {
  const sup = makeSupervisor();
  const idle = sup.create("local", "m1", "idle");
  const busy = sup.create("local", "m1", "busy");
  busy.busy = true;
  const parked = sup.create("local", "m1", "parked");
  parked.ledger.raise("u1", "confirm", () => {});
  const cold = sup.create("local", "m1", "cold");
  sup.gc(cold);

  const byId = new Map(sup.list().map((s) => [s.id, s]));
  expect(byId.get(idle.id)?.state).toBe("live-idle");
  expect(byId.get(busy.id)?.state).toBe("live-busy");
  expect(byId.get(parked.id)?.state).toBe("parked");
  expect(byId.get(cold.id)?.state).toBe("cold");
  expect(byId.get(cold.id)?.name).toBe("cold");
  expect(byId.get(idle.id)?.executor).toBe("exec-1");
});
