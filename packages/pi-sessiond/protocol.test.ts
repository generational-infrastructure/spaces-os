// protocol.ts unit tests: the §12 envelope grammar (docs/remote-pi-design.md).
//
// Three suites:
//   1. parseClientEnvelope — tolerant normalization mirroring the daemon's
//      historical behavior (bad field types degrade, never throw).
//   2. parseServerEnvelope + builders — strict validation of what the daemon
//      emits, including the requestId create-ack correlation echo.
//   3. Fixture-corpus conformance — every frame in protocol-fixtures/*.json
//      parses in its direction and survives a serialize→reparse round-trip
//      byte-identically, so the corpus stays the canonical wire reference the
//      python fake daemons are held to.
import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import {
  attachedEnvelope,
  deletedEnvelope,
  errorEnvelope,
  eventEnvelope,
  parseClientEnvelope,
  parseServerEnvelope,
  PROTOCOL_VERSION,
  serializeEnvelope,
  type ServerEnvelope,
  sessionsEnvelope,
  sidechannelResolvedEnvelope,
  welcomeEnvelope,
} from "./protocol";

function clientOk(text: string) {
  const res = parseClientEnvelope(text);
  if (!res.ok) throw new Error(`expected ok, got: ${res.error}`);
  return res.envelope;
}

function serverOk(text: string) {
  const res = parseServerEnvelope(text);
  if (!res.ok) throw new Error(`expected ok, got: ${res.error}`);
  return res.envelope;
}

describe("parseClientEnvelope", () => {
  test("rejects invalid json", () => {
    const res = parseClientEnvelope("{nope");
    expect(res.ok).toBe(false);
    if (!res.ok) {
      expect(res.error).toBe("invalid json");
      expect(res.unknownKind).toBeUndefined();
    }
  });

  test("rejects non-record envelopes", () => {
    for (const text of ["42", '"str"', "null", "[1]"]) {
      const res = parseClientEnvelope(text);
      expect(res.ok).toBe(false);
      if (!res.ok) expect(res.error).toBe("invalid envelope");
    }
  });

  test("flags unknown kinds without claiming the envelope malformed", () => {
    const res = parseClientEnvelope(JSON.stringify({ v: 1, kind: "bogus" }));
    expect(res.ok).toBe(false);
    if (!res.ok) {
      expect(res.error).toBe("unknown kind: bogus");
      expect(res.unknownKind).toBe(true);
    }
  });

  test("flags a missing kind as (none)", () => {
    const res = parseClientEnvelope(JSON.stringify({ v: 1 }));
    expect(res.ok).toBe(false);
    if (!res.ok) {
      expect(res.error).toBe("unknown kind: (none)");
      expect(res.unknownKind).toBe(true);
    }
  });

  test("hello: token/client normalized, junk dropped", () => {
    const env = clientOk(
      JSON.stringify({
        v: 1,
        kind: "hello",
        token: "t",
        client: { name: "pi-web" },
      }),
    );
    expect(env).toEqual({
      v: 1,
      kind: "hello",
      token: "t",
      client: { name: "pi-web" },
    });
    const bare = clientOk(JSON.stringify({ kind: "hello", token: 42 }));
    expect(bare).toEqual({ v: 1, kind: "hello" });
  });

  test("create_session: optional fields kept only as strings", () => {
    const env = clientOk(
      JSON.stringify({
        v: 1,
        kind: "create_session",
        name: "web",
        provider: "local",
        model: "m",
        requestId: "req-1",
      }),
    );
    expect(env).toEqual({
      v: 1,
      kind: "create_session",
      name: "web",
      provider: "local",
      model: "m",
      requestId: "req-1",
    });
    // Legacy uncorrelated create (QML, wave 3): no requestId — still valid.
    const legacy = clientOk(
      JSON.stringify({ v: 1, kind: "create_session", requestId: 7 }),
    );
    expect(legacy).toEqual({ v: 1, kind: "create_session" });
  });

  test("attach: sessionId degrades to empty string, lastSeq to absent", () => {
    const env = clientOk(
      JSON.stringify({ v: 1, kind: "attach", sessionId: "s1", lastSeq: 12 }),
    );
    expect(env).toEqual({ v: 1, kind: "attach", sessionId: "s1", lastSeq: 12 });
    const junk = clientOk(
      JSON.stringify({ v: 1, kind: "attach", sessionId: 9, lastSeq: "x" }),
    );
    expect(junk).toEqual({ v: 1, kind: "attach", sessionId: "" });
  });

  test("detach / delete_session / list_sessions", () => {
    expect(
      clientOk(JSON.stringify({ v: 1, kind: "detach", sessionId: "s" })),
    ).toEqual({ v: 1, kind: "detach", sessionId: "s" });
    expect(
      clientOk(
        JSON.stringify({ v: 1, kind: "delete_session", sessionId: "s" }),
      ),
    ).toEqual({ v: 1, kind: "delete_session", sessionId: "s" });
    expect(clientOk(JSON.stringify({ v: 1, kind: "list_sessions" }))).toEqual({
      v: 1,
      kind: "list_sessions",
    });
  });

  test("command: payload kept only when a record", () => {
    const env = clientOk(
      JSON.stringify({
        v: 1,
        kind: "command",
        sessionId: "s",
        payload: { type: "prompt", message: "hi" },
      }),
    );
    expect(env).toEqual({
      v: 1,
      kind: "command",
      sessionId: "s",
      payload: { type: "prompt", message: "hi" },
    });
    const junk = clientOk(
      JSON.stringify({ v: 1, kind: "command", sessionId: "s", payload: 3 }),
    );
    expect(junk).toEqual({ v: 1, kind: "command", sessionId: "s" });
  });
});

describe("parseServerEnvelope", () => {
  test("requires v === PROTOCOL_VERSION", () => {
    const res = parseServerEnvelope(
      JSON.stringify({ kind: "welcome", connectionId: "c1", caps: {} }),
    );
    expect(res.ok).toBe(false);
  });

  test("welcome: connectionId required, caps.executor optional", () => {
    expect(
      serverOk(
        JSON.stringify({
          v: 1,
          kind: "welcome",
          connectionId: "c1",
          caps: { executor: "host" },
        }),
      ),
    ).toEqual({
      v: 1,
      kind: "welcome",
      connectionId: "c1",
      caps: { executor: "host" },
    });
    // Sparse caps (older fake daemons) still conform.
    expect(
      serverOk(
        JSON.stringify({ v: 1, kind: "welcome", connectionId: "c1", caps: {} }),
      ),
    ).toEqual({ v: 1, kind: "welcome", connectionId: "c1", caps: {} });
    const bad = parseServerEnvelope(JSON.stringify({ v: 1, kind: "welcome" }));
    expect(bad.ok).toBe(false);
  });

  test("sessions: every entry must be a full SessionInfo", () => {
    const good = JSON.stringify({
      v: 1,
      kind: "sessions",
      sessions: [
        {
          id: "s1",
          name: "Chat 1",
          executor: "host",
          state: "live-idle",
          updated: 123,
        },
      ],
    });
    const env = serverOk(good);
    if (env.kind !== "sessions") throw new Error("wrong kind");
    expect(env.sessions[0].executor).toBe("host");
    // Missing executor (the old pi-web local SessionInfo) is a violation.
    const missing = parseServerEnvelope(
      JSON.stringify({
        v: 1,
        kind: "sessions",
        sessions: [{ id: "s1", name: "x", state: "live-idle", updated: 1 }],
      }),
    );
    expect(missing.ok).toBe(false);
    const badState = parseServerEnvelope(
      JSON.stringify({
        v: 1,
        kind: "sessions",
        sessions: [
          { id: "s1", name: "x", executor: "h", state: "warm", updated: 1 },
        ],
      }),
    );
    expect(badState.ok).toBe(false);
  });

  test("attached: seq required; created and requestId optional", () => {
    expect(
      serverOk(
        JSON.stringify({ v: 1, kind: "attached", sessionId: "s1", seq: 4 }),
      ),
    ).toEqual({ v: 1, kind: "attached", sessionId: "s1", seq: 4 });
    expect(
      serverOk(
        JSON.stringify({
          v: 1,
          kind: "attached",
          sessionId: "s1",
          seq: 0,
          created: true,
          requestId: "req-9",
        }),
      ),
    ).toEqual({
      v: 1,
      kind: "attached",
      sessionId: "s1",
      seq: 0,
      created: true,
      requestId: "req-9",
    });
    const noSeq = parseServerEnvelope(
      JSON.stringify({ v: 1, kind: "attached", sessionId: "s1" }),
    );
    expect(noSeq.ok).toBe(false);
  });

  test("event / sidechannel_resolved / deleted / error", () => {
    expect(
      serverOk(
        JSON.stringify({
          v: 1,
          kind: "event",
          sessionId: "s1",
          seq: 7,
          payload: { type: "agent_start" },
        }),
      ),
    ).toEqual({
      v: 1,
      kind: "event",
      sessionId: "s1",
      seq: 7,
      payload: { type: "agent_start" },
    });
    expect(
      serverOk(
        JSON.stringify({
          v: 1,
          kind: "sidechannel_resolved",
          sessionId: "s1",
          id: "sc-1",
          by: "",
        }),
      ),
    ).toEqual({
      v: 1,
      kind: "sidechannel_resolved",
      sessionId: "s1",
      id: "sc-1",
      by: "",
    });
    expect(
      serverOk(JSON.stringify({ v: 1, kind: "deleted", sessionId: "s1" })),
    ).toEqual({ v: 1, kind: "deleted", sessionId: "s1" });
    expect(
      serverOk(
        JSON.stringify({
          v: 1,
          kind: "error",
          error: "no such session",
          sessionId: "s1",
          requestId: "req-2",
        }),
      ),
    ).toEqual({
      v: 1,
      kind: "error",
      error: "no such session",
      sessionId: "s1",
      requestId: "req-2",
    });
  });
});

describe("builders", () => {
  test("attachedEnvelope echoes requestId verbatim and omits empty options", () => {
    expect(attachedEnvelope("s1", 3)).toEqual({
      v: 1,
      kind: "attached",
      sessionId: "s1",
      seq: 3,
    });
    expect(
      attachedEnvelope("s1", 0, { created: true, requestId: "req-☂ exact" }),
    ).toEqual({
      v: 1,
      kind: "attached",
      sessionId: "s1",
      seq: 0,
      created: true,
      requestId: "req-☂ exact",
    });
  });

  test("errorEnvelope carries sessionId/requestId only when given", () => {
    expect(errorEnvelope("boom")).toEqual({
      v: 1,
      kind: "error",
      error: "boom",
    });
    expect(errorEnvelope("boom", { sessionId: "s1", requestId: "r1" })).toEqual(
      { v: 1, kind: "error", error: "boom", sessionId: "s1", requestId: "r1" },
    );
    // Empty strings are omitted (sendNoSuchSession's "" sessionId contract).
    expect(errorEnvelope("boom", { sessionId: "" })).toEqual({
      v: 1,
      kind: "error",
      error: "boom",
    });
  });

  test("every builder output round-trips through parseServerEnvelope", () => {
    const envs: ServerEnvelope[] = [
      welcomeEnvelope("c1", "host"),
      sessionsEnvelope([
        {
          id: "s1",
          name: "n",
          executor: "host",
          state: "cold",
          updated: 1,
        },
      ]),
      attachedEnvelope("s1", 0, { created: true, requestId: "r" }),
      eventEnvelope("s1", 1, { type: "agent_start" }),
      sidechannelResolvedEnvelope("s1", "sc-1", "c2"),
      deletedEnvelope("s1"),
      errorEnvelope("nope", { sessionId: "s1" }),
    ];
    for (const env of envs) {
      const res = parseServerEnvelope(serializeEnvelope(env));
      expect(res.ok).toBe(true);
      if (res.ok) expect(res.envelope).toEqual(env);
    }
  });
});

describe("fixture corpus conformance", () => {
  const dir = `${import.meta.dir}/protocol-fixtures`;
  const files = readdirSync(dir).filter((f) => f.endsWith(".json"));

  test("corpus is non-empty", () => {
    expect(files.length).toBeGreaterThan(0);
  });

  for (const file of files) {
    test(file, () => {
      const doc = JSON.parse(readFileSync(`${dir}/${file}`, "utf8"));
      expect(typeof doc.description).toBe("string");
      expect(Array.isArray(doc.frames)).toBe(true);
      expect(doc.frames.length).toBeGreaterThan(0);
      expect(doc.v).toBe(PROTOCOL_VERSION);
      for (const frame of doc.frames) {
        expect(frame.dir === "client" || frame.dir === "server").toBe(true);
        const text = JSON.stringify(frame.envelope);
        if (frame.dir === "client") {
          const res = parseClientEnvelope(text);
          if (!res.ok) throw new Error(`${file}: ${res.error}: ${text}`);
          // Canonical frames must be lossless under normalization: nothing in
          // the corpus may rely on tolerated junk fields.
          expect(res.envelope).toEqual(frame.envelope);
          expect(JSON.parse(serializeEnvelope(res.envelope))).toEqual(
            frame.envelope,
          );
        } else {
          const res = parseServerEnvelope(text);
          if (!res.ok) throw new Error(`${file}: ${res.error}: ${text}`);
          expect(res.envelope).toEqual(frame.envelope);
          expect(JSON.parse(serializeEnvelope(res.envelope))).toEqual(
            frame.envelope,
          );
        }
      }
    });
  }
});
