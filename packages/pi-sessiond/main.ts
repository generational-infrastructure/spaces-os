#!/usr/bin/env bun
/**
 * pi-sessiond — remote-pi executor daemon (docs/remote-pi-design.md).
 *
 * A token-authenticated WebSocket transport (§12 envelope) in front of a
 * registry of `pi --mode rpc` subprocesses, one per session. The daemon parses
 * pi's stdout *shallowly*: it splits LF-delimited JSON (never via readline —
 * that also breaks on U+2028 / U+2029, §5.2), stamps each event with a
 * per-session monotonic `seq`, and forwards it verbatim inside an `event`
 * envelope. Client commands are written to the owning subprocess's stdin.
 *
 * First green increment: spawns pi directly. The systemd-run sandbox (§8) and
 * session.jsonl persistence + reconnect (§14 stage 3) are later, separately
 * tested increments; this is the minimum that satisfies the remote-session
 * contract in checks/pi-remote-session.
 */

import { spawn, type ChildProcess } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { randomUUID } from "node:crypto";
import type { Writable } from "node:stream";
import { resolve } from "node:path";
import type { ServerWebSocket } from "bun";
import { buildSpawnCommand } from "./sandbox";

// ---- configuration (NixOS module → systemd env) --------------------------

const HOST = process.env.SPACES_SESSIOND_HOST ?? "127.0.0.1";
const PORT = Number(process.env.SPACES_SESSIOND_PORT ?? "8770");
const EXECUTOR_ID = process.env.SPACES_SESSIOND_EXECUTOR_ID ?? "local";
const DEFAULT_MODEL = process.env.SPACES_SESSIOND_DEFAULT_MODEL ?? "";
const DEFAULT_PROVIDER = process.env.SPACES_SESSIOND_DEFAULT_PROVIDER ?? "local";
const LLM_URL = process.env.LLAMA_SWAP_BASE_URL ?? "";
const PI_BIN = process.env.PI_BIN ?? "pi";
const SETTINGS_TEMPLATE = process.env.SPACES_SESSIOND_PI_SETTINGS ?? "";
// $STATE_DIRECTORY is only the relative name; SPACES_SESSIOND_STATE_DIR is the
// absolute path. resolve() guarantees an absolute base either way, so the
// PI_CODING_AGENT_DIR handed to pi (whose cwd is the session workdir) is
// absolute and resolves to *this* agent dir, not somewhere under the workdir.
const STATE_DIR = resolve(
  process.env.SPACES_SESSIOND_STATE_DIR ??
    process.env.STATE_DIRECTORY ??
    "/tmp/pi-sessiond",
);
const SYSTEMD_RUN = process.env.SPACES_SESSIOND_SYSTEMD_RUN ?? "systemd-run";
const MEMORY_HIGH = process.env.SPACES_SESSIOND_MEMORY_HIGH ?? "4G";

function loadToken(): string {
  const credDir = process.env.CREDENTIALS_DIRECTORY;
  if (credDir) {
    try {
      return readFileSync(`${credDir}/token`, "utf8").trim();
    } catch {
      // No credential file — fall through to the inline env token.
    }
  }
  return (process.env.SPACES_SESSIOND_TOKEN ?? "").trim();
}
const TOKEN = loadToken();

// One writable pi agent dir, seeded from the module's settings.json template.
// pi reads settings.json from here and writes auth.json / *.lock dirs back.
const AGENT_DIR = `${STATE_DIR}/pi-agent`;
mkdirSync(AGENT_DIR, { recursive: true });
mkdirSync(`${STATE_DIR}/sessions`, { recursive: true });
if (SETTINGS_TEMPLATE) {
  copyFileSync(SETTINGS_TEMPLATE, `${AGENT_DIR}/settings.json`);
}

// ---- helpers over unvalidated client input --------------------------------

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}
function asNumber(value: unknown): number | undefined {
  return typeof value === "number" ? value : undefined;
}

// A session id is always a randomUUID() we minted. Validating the shape before
// it builds filesystem paths (sessions/<id>, <id>.meta.json) closes a path-
// traversal hole on the client-supplied attach.sessionId.
const SESSION_ID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
function isSessionId(value: string): boolean {
  return SESSION_ID_RE.test(value);
}

// ---- connection + session state -------------------------------------------

interface ConnData {
  id: string;
  authed: boolean;
}
type Conn = ServerWebSocket<ConnData>;

// Recent events per session, replayed to a (re)attaching client so it catches
// up (warm reconnect / mirror). Capped — history beyond the window will need a
// get_messages snapshot (follow-up).
interface BufferedEvent {
  seq: number;
  data: string;
}
const BUFFER_CAP = 4096;

interface Session {
  id: string;
  proc: ChildProcess;
  stdin: Writable;
  seq: number;
  subscribers: Set<Conn>;
  buffer: BufferedEvent[];
}
const sessions = new Map<string, Session>();

function send(ws: Conn, msg: unknown): void {
  ws.send(JSON.stringify(msg));
}

// Stamp a session event with the next monotonic seq and fan it out verbatim.
function broadcast(session: Session, payload: unknown): void {
  session.seq += 1;
  const data = JSON.stringify({
    v: 1,
    kind: "event",
    sessionId: session.id,
    seq: session.seq,
    payload,
  });
  session.buffer.push({ seq: session.seq, data });
  if (session.buffer.length > BUFFER_CAP) session.buffer.shift();
  for (const ws of session.subscribers) ws.send(data);
}

// Split a byte stream on LF only — protocol-compliant, unlike readline which
// also breaks on U+2028 / U+2029 (design §5.2).
function lineSplitter(onLine: (line: string) => void): (chunk: Buffer) => void {
  let buf = Buffer.alloc(0);
  return (chunk: Buffer) => {
    buf = buf.length === 0 ? chunk : Buffer.concat([buf, chunk]);
    let nl = buf.indexOf(0x0a);
    while (nl !== -1) {
      const line = buf.subarray(0, nl).toString("utf8");
      buf = buf.subarray(nl + 1);
      if (line.length > 0) onLine(line);
      nl = buf.indexOf(0x0a);
    }
  };
}

// ---- session lifecycle -----------------------------------------------------

function sessionDirOf(id: string): string {
  return `${STATE_DIR}/sessions/${id}`;
}
function workdirOf(id: string): string {
  return `${STATE_DIR}/workspaces/${id}`;
}
// Sibling of the session dir (not inside it) so pi never sees the daemon's
// bookkeeping file in its --session-dir.
function metaPathOf(id: string): string {
  return `${STATE_DIR}/sessions/${id}.meta.json`;
}

// Persisted per-session metadata, so a session can be resurrected from disk
// with the right provider/model after the subprocess or the daemon restarts.
interface SessionMeta {
  provider: string;
  model: string;
}
function writeSessionMeta(id: string, meta: SessionMeta): void {
  writeFileSync(metaPathOf(id), JSON.stringify(meta));
}
function readSessionMeta(id: string): SessionMeta | undefined {
  let raw: string;
  try {
    raw = readFileSync(metaPathOf(id), "utf8");
  } catch {
    return undefined;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return undefined;
  }
  if (!isRecord(parsed)) return undefined;
  const provider = asString(parsed.provider);
  const model = asString(parsed.model);
  if (provider === undefined || model === undefined) return undefined;
  return { provider, model };
}
// Has pi committed at least one turn here? --continue only makes sense then;
// on an empty dir pi falls back to a fresh session (noisily).
function hasCommittedSession(id: string): boolean {
  try {
    return readdirSync(sessionDirOf(id)).some((f) => f.endsWith(".jsonl"));
  } catch {
    return false;
  }
}

interface SpawnOpts {
  id: string;
  provider: string;
  model: string;
  continueSession: boolean;
}

// Spawn a sandboxed `pi --mode rpc` for a session and register it live.
function spawnSession(opts: SpawnOpts): Session {
  const { id, provider, model, continueSession } = opts;
  const workdir = workdirOf(id);
  const sessionDir = sessionDirOf(id);
  mkdirSync(workdir, { recursive: true });
  mkdirSync(sessionDir, { recursive: true });

  const { argv, env } = buildSpawnCommand({
    systemdRun: SYSTEMD_RUN,
    piBin: PI_BIN,
    sessionId: id,
    sessionDir,
    workdir,
    agentDir: AGENT_DIR,
    llmUrl: LLM_URL,
    provider,
    model,
    memoryHigh: MEMORY_HIGH,
    path: process.env.PATH ?? "",
    trusted: false,
    continueSession,
  });

  const proc = spawn(argv[0], argv.slice(1), {
    cwd: workdir,
    stdio: ["pipe", "pipe", "inherit"],
    env: { ...process.env, ...env },
  });

  const { stdout, stdin } = proc;
  if (!stdout || !stdin) {
    proc.kill();
    throw new Error("pi subprocess started without stdio pipes");
  }

  const session: Session = {
    id,
    proc,
    stdin,
    seq: 0,
    subscribers: new Set(),
    buffer: [],
  };
  sessions.set(id, session);

  stdout.on(
    "data",
    lineSplitter((line) => {
      let event: unknown;
      try {
        event = JSON.parse(line);
      } catch {
        return; // pi emits only JSON lines; ignore anything else.
      }
      broadcast(session, event);
    }),
  );

  proc.on("exit", (code) => {
    broadcast(session, { type: "session_exit", code });
    sessions.delete(id);
  });

  return session;
}

// A brand-new session: mint an id, spawn fresh (no --continue), and persist
// its provider/model so it can be resurrected from disk later.
function createSession(provider: string, model: string): Session {
  const id = randomUUID();
  const session = spawnSession({ id, provider, model, continueSession: false });
  writeSessionMeta(id, { provider, model });
  return session;
}

// Resurrect a session whose subprocess is gone (GC'd, crashed, or the daemon
// restarted) from its committed jsonl on disk. Returns undefined when nothing
// is persisted under this id (design §5.1: attach to cold -> spawn --continue).
function resumeSession(id: string): Session | undefined {
  if (!isSessionId(id)) return undefined;
  const meta = readSessionMeta(id);
  if (!meta) return undefined;
  return spawnSession({
    id,
    provider: meta.provider,
    model: meta.model,
    continueSession: hasCommittedSession(id),
  });
}

// A subprocess that has exited (exit code or signal set) no longer serves its
// session; a still-mapped entry like that is cold, so attach resurrects it.
function isAlive(session: Session): boolean {
  return session.proc.exitCode === null && session.proc.signalCode === null;
}

// ---- envelope dispatch -----------------------------------------------------

function handleMessage(ws: Conn, text: string): void {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    send(ws, { v: 1, kind: "error", error: "invalid json" });
    return;
  }
  if (!isRecord(parsed)) {
    send(ws, { v: 1, kind: "error", error: "invalid envelope" });
    return;
  }
  const kind = asString(parsed.kind);

  if (kind === "hello") {
    if (TOKEN.length > 0 && asString(parsed.token) !== TOKEN) {
      send(ws, { v: 1, kind: "error", error: "unauthorized" });
      ws.close(4001, "unauthorized");
      return;
    }
    ws.data.authed = true;
    send(ws, {
      v: 1,
      kind: "welcome",
      connectionId: ws.data.id,
      caps: { executor: EXECUTOR_ID },
    });
    return;
  }

  if (!ws.data.authed) {
    send(ws, { v: 1, kind: "error", error: "not authenticated" });
    ws.close(4001, "unauthorized");
    return;
  }

  switch (kind) {
    case "create_session": {
      const provider = asString(parsed.provider) ?? DEFAULT_PROVIDER;
      const model = asString(parsed.model) ?? DEFAULT_MODEL;
      const session = createSession(provider, model);
      session.subscribers.add(ws);
      send(ws, { v: 1, kind: "attached", sessionId: session.id, seq: session.seq });
      return;
    }
    case "attach": {
      const sessionId = asString(parsed.sessionId) ?? "";
      let session = sessions.get(sessionId);
      // A mapped-but-dead subprocess (exit not yet reaped, or stopped out from
      // under us) is cold: drop it and resurrect from the committed jsonl.
      if (session && !isAlive(session)) {
        sessions.delete(sessionId);
        session = undefined;
      }
      session ??= resumeSession(sessionId);
      if (!session) {
        send(ws, { v: 1, kind: "error", error: "no such session" });
        return;
      }
      session.subscribers.add(ws);
      send(ws, { v: 1, kind: "attached", sessionId: session.id, seq: session.seq });
      // Replay buffered events the client hasn't seen so it catches up.
      const lastSeq = asNumber(parsed.lastSeq) ?? 0;
      for (const ev of session.buffer) {
        if (ev.seq > lastSeq) ws.send(ev.data);
      }
      return;
    }
    case "detach": {
      const session = sessions.get(asString(parsed.sessionId) ?? "");
      session?.subscribers.delete(ws);
      return;
    }
    case "command": {
      const session = sessions.get(asString(parsed.sessionId) ?? "");
      if (!session) {
        send(ws, { v: 1, kind: "error", error: "no such session" });
        return;
      }
      // The payload is pi's own command, forwarded verbatim to stdin.
      session.stdin.write(`${JSON.stringify(parsed.payload)}\n`);
      return;
    }
    default:
      send(ws, { v: 1, kind: "error", error: `unknown kind: ${kind ?? "(none)"}` });
  }
}

// ---- WebSocket server ------------------------------------------------------

Bun.serve<ConnData>({
  hostname: HOST,
  port: PORT,
  fetch(req, server) {
    if (server.upgrade(req, { data: { id: randomUUID(), authed: false } })) {
      return undefined;
    }
    return new Response("pi-sessiond: websocket only", { status: 426 });
  },
  websocket: {
    message(ws, message) {
      handleMessage(ws, typeof message === "string" ? message : message.toString("utf8"));
    },
    close(ws) {
      for (const session of sessions.values()) session.subscribers.delete(ws);
    },
  },
});

console.error(
  `pi-sessiond: listening on ${HOST}:${PORT} (executor ${EXECUTOR_ID}); ` +
    `agentDir=${AGENT_DIR} settings=${existsSync(`${AGENT_DIR}/settings.json`)}`,
);
