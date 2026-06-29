#!/usr/bin/env bun
/**
 * pi-sessiond — remote-pi executor daemon (docs/remote-pi-design.md).
 *
 * Embeds pi via its SDK (@earendil-works/pi-coding-agent): one in-process
 * `AgentSession` per chat session. A token-authenticated WebSocket transport
 * (§12) fans each session's typed event stream out to attached clients in
 * seq-stamped envelopes, and routes inbound `command` payloads into the session
 * (prompt/abort/setModel/…). pi's built-in `bash` is replaced by a tool whose
 * operations wrap every command in a `systemd-run` confinement unit (§8);
 * confirm/input/select requests surface through the session's `uiContext` and
 * route to clients as side channels (§6, block-and-notify).
 *
 * The §12 wire protocol is unchanged from the subprocess era — clients see the
 * same pi event/command shapes, now sourced from the SDK rather than parsed
 * from `pi --mode rpc` stdout.
 */

import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  chownSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import type { ServerWebSocket } from "bun";
import { AuthStorage, ModelRegistry } from "@earendil-works/pi-coding-agent";
import { RpcDriver, type RpcFrame } from "./rpc-driver";
import {
  type AllowedPath,
  buildLandlockPolicy,
  buildLandlockUnitArgv,
} from "./sandbox";
import { startCredentialProxy } from "./proxy";
import { stageFile } from "./staging";
import { fetchModels } from "./provider";

// ---- configuration (NixOS module → systemd env) --------------------------

const HOST = process.env.SPACES_SESSIOND_HOST ?? "127.0.0.1";
const PORT = Number(process.env.SPACES_SESSIOND_PORT ?? "8770");
const EXECUTOR_ID = process.env.SPACES_SESSIOND_EXECUTOR_ID ?? "local";
const DEFAULT_MODEL = process.env.SPACES_SESSIOND_DEFAULT_MODEL ?? "";
const DEFAULT_PROVIDER =
  process.env.SPACES_SESSIOND_DEFAULT_PROVIDER ?? "local";
const LLM_URL = process.env.LLAMA_SWAP_BASE_URL ?? "";
const SETTINGS_TEMPLATE = process.env.SPACES_SESSIOND_PI_SETTINGS ?? "";
const PWA_DIR = process.env.SPACES_SESSIOND_PWA_DIR ?? "";
const STATE_DIR = resolve(
  process.env.SPACES_SESSIOND_STATE_DIR ??
    process.env.STATE_DIRECTORY ??
    "/tmp/pi-sessiond",
);
// systemd-run that wraps each per-session pi child in its Landlock confinement
// unit (sandbox.ts). The runtime is always sandboxed. Production points this at
// the real `systemd-run` (`--user` for the desktop user service, system scope
// for the server); the cheap checks point it at a passthrough stub that strips
// the unit flags, applies --setenv, and execs the launcher + child directly.
const SYSTEMD_RUN = process.env.SPACES_SESSIOND_SYSTEMD_RUN ?? "systemd-run";
// pi-landlock-exec, the per-session Landlock launcher (sandbox.ts / design §6):
// the sole sandbox path. main.ts writes a per-session landlockconfig policy and
// execs the child through the launcher, which applies the self-applied domain
// before pi. Required — the daemon refuses to start without it.
const LANDLOCK_EXEC = process.env.SPACES_SESSIOND_LANDLOCK_EXEC ?? "";
if (!LANDLOCK_EXEC) {
  throw new Error(
    "pi-sessiond: SPACES_SESSIOND_LANDLOCK_EXEC is required (the per-session Landlock launcher)",
  );
}
// System/remote executor: the root daemon drops each per-session unit to this
// fixed non-root user and chowns the session's dirs to it (Landlock confines
// but does not drop privilege). Resolved to uid/gid from /etc/passwd. Empty on
// the desktop user service, whose unit already runs as the daemon's own uid.
const SESSION_USER = process.env.SPACES_SESSIOND_SESSION_USER ?? "";
function resolveUser(name: string): { uid: number; gid: number } {
  const line = readFileSync("/etc/passwd", "utf8")
    .split("\n")
    .find((l) => l.startsWith(`${name}:`));
  if (!line) {
    throw new Error(
      `pi-sessiond: SPACES_SESSIOND_SESSION_USER=${name} not in /etc/passwd`,
    );
  }
  const fields = line.split(":");
  return { uid: Number(fields[2]), gid: Number(fields[3]) };
}
const SESSION_IDS = SESSION_USER ? resolveUser(SESSION_USER) : undefined;
// pi binary spawned per session in rpc-mode (or a stub, in tests).
const PI_BIN = process.env.SPACES_SESSIOND_PI_BIN ?? "pi";
const MEMORY_HIGH = process.env.SPACES_SESSIOND_MEMORY_HIGH ?? "4G";
// Skill plumbing for the per-session pi runtime (NixOS module → JSON env).
// SPACES_SESSIOND_SESSION_ENV: { VAR: value } --setenv'd into the session unit
// (SKILL_CONFIG_SOCKET, SPACES_NOTIFICATIONS_FILE, …). SPACES_SESSIOND_ALLOWED_PATHS:
// [{ source, mode }] folded into the session's Landlock FS allowlist — the
// whole domain, inherited by every tool/bash/extension, not a separate bash
// sandbox. Paths arrive pre-expanded — systemd resolves %h/%t in the module's
// Environment= lines before the daemon ever sees them.
function jsonEnv<T>(name: string, fallback: T): T {
  const raw = process.env[name];
  if (!raw) return fallback;
  try {
    return JSON.parse(raw) as T;
  } catch (err) {
    console.error(`pi-sessiond: ignoring malformed ${name}: ${String(err)}`);
    return fallback;
  }
}
const SESSION_ENV = jsonEnv<Record<string, string>>(
  "SPACES_SESSIOND_SESSION_ENV",
  {},
);
const ALLOWED_PATHS = jsonEnv<AllowedPath[]>(
  "SPACES_SESSIOND_ALLOWED_PATHS",
  [],
);
// bash-confirm allow-list template, staged next to settings.json (the
// bash-confirm extension reads $PI_CODING_AGENT_DIR/bash-confirm.json).
const BASH_CONFIRM_TEMPLATE = process.env.SPACES_SESSIOND_BASH_CONFIRM ?? "";
// Env the sandboxed child needs but cannot inherit (its unit gets a fresh
// env): the provider endpoint, the memory store, telemetry opt-outs, and PATH
// for the in-sandbox bash + skill CLIs. Curated allowlist — secrets (the LLM
// key) never cross into the sandbox.
function childPassthroughEnv(): Record<string, string> {
  const out: Record<string, string> = {};
  for (const k of [
    "PATH",
    "LLAMA_SWAP_BASE_URL",
    "SEDIMENT_DB",
    "HF_HOME",
    "PI_OFFLINE",
    "PI_TELEMETRY",
  ]) {
    const v = process.env[k];
    if (v !== undefined) out[k] = v;
  }
  return out;
}
// A live-idle session with no attached clients is disposed after
// IDLE_TIMEOUT_MS (0 disables); MAX_LIVE caps resident sessions (0 = unlimited).
// Both rely on the child re-reading the jsonl from its session-dir on the
// next attach (the supervisor respawns a fresh pi child for it).
const IDLE_TIMEOUT_MS = Number(
  process.env.SPACES_SESSIOND_IDLE_TIMEOUT_MS ?? "1800000",
);
const GC_INTERVAL_MS = Math.min(
  60000,
  Math.max(1000, Math.floor(IDLE_TIMEOUT_MS / 4)),
);
const MAX_LIVE = Number(process.env.SPACES_SESSIOND_MAX_LIVE ?? "0");
// Notifier (design §6/§7): run when a side-channel request parks with zero
// clients attached, so the user is reached out-of-band. SPACES_NOTIFY_* env.
const NOTIFY_CMD = process.env.SPACES_SESSIOND_NOTIFY_CMD ?? "";

// Peer executors in the same clan instance, surfaced to PWA clients via
// `GET /executors` so they can fan out their own WS connections (fleet view).
// Format: JSON `[{ "id": "kiwi", "host": "agent-kiwi.pin" }, …]` — the host
// is whatever public name fronts each peer's WS (Caddy reverse-proxy origin).
// SPACES_SESSIOND_PEERS_FILE wins over the inline env so the clan module can
// stage it as a normal file without touching the systemd unit's Environment
// (the inline form is for tests). The local executor itself is included so
// the list is the whole fleet, not "the others".
function loadPeers(): { id: string; host: string }[] {
  const path = process.env.SPACES_SESSIOND_PEERS_FILE ?? "";
  const inline = process.env.SPACES_SESSIOND_PEERS ?? "";
  let raw = "";
  if (path.length > 0) {
    try {
      raw = readFileSync(path, "utf8");
    } catch {
      // Falls through to inline; an empty list is a valid clan-of-one.
    }
  }
  if (raw.length === 0) raw = inline;
  if (raw.trim().length === 0) return [];
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.flatMap((entry): { id: string; host: string }[] => {
      if (!entry || typeof entry !== "object") return [];
      const id = (entry as { id?: unknown }).id;
      const host = (entry as { host?: unknown }).host;
      if (typeof id !== "string" || typeof host !== "string") return [];
      if (id.length === 0 || host.length === 0) return [];
      return [{ id, host }];
    });
  } catch {
    console.error("pi-sessiond: malformed SPACES_SESSIOND_PEERS, ignoring");
    return [];
  }
}
const PEERS = loadPeers();

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

// OpenRouter (optional): the module stages its API key via LoadCredential, so
// it lands in $CREDENTIALS_DIRECTORY alongside the token. Empty = not enabled.
function loadOpenRouterKey(): string {
  const credDir = process.env.CREDENTIALS_DIRECTORY;
  if (credDir) {
    try {
      return readFileSync(`${credDir}/openrouter-api-key`, "utf8").trim();
    } catch {
      // OpenRouter not configured for this executor.
    }
  }
  return "";
}
const OPENROUTER_KEY = loadOpenRouterKey();

// llama-swap API key (optional): when the clan `pi` service protects this
// executor's llama-swap with a shared key, the daemon must send it on model
// discovery and every completion. Staged via LoadCredential alongside the
// token; falls back to an inline env (tests) and finally "dummy" so a
// default-allow llama-swap keeps working unchanged.
function loadLlamaSwapKey(): string {
  const credDir = process.env.CREDENTIALS_DIRECTORY;
  if (credDir) {
    try {
      const key = readFileSync(`${credDir}/llama-swap-api-key`, "utf8").trim();
      if (key) return key;
    } catch {
      // No credential file — fall through to the inline env / default.
    }
  }
  return (process.env.SPACES_SESSIOND_LLM_API_KEY ?? "").trim() || "dummy";
}
const LLAMA_SWAP_KEY = loadLlamaSwapKey();

// The LLM loop runs in the session sandbox, but the OpenRouter key stays in the
// supervisor: run a loopback proxy that injects it (proxy.ts, §6.2) and hand
// sessions only its URL + a dummy key. Empty when no key is configured —
// OpenRouter is then simply unavailable inside sessions.
const openRouterProxy = OPENROUTER_KEY
  ? startCredentialProxy({
      key: OPENROUTER_KEY,
      upstream: "https://openrouter.ai/api/v1",
    })
  : undefined;
const OPENROUTER_PROXY_URL = openRouterProxy
  ? `http://127.0.0.1:${openRouterProxy.port}`
  : "";
// The credential-proxy TCP port — the only egress the Landlock policy allows.
const PROXY_PORT = openRouterProxy?.port;

// One writable pi agent dir (HOME / PI_CODING_AGENT_DIR), seeded from the
// module's settings.json template. pi reads settings.json here and writes
// auth.json / sessions / *.lock back.
const AGENT_DIR = `${STATE_DIR}/pi-agent`;
mkdirSync(AGENT_DIR, { recursive: true });
mkdirSync(`${STATE_DIR}/sessions`, { recursive: true });
if (SETTINGS_TEMPLATE) {
  stageFile(SETTINGS_TEMPLATE, `${AGENT_DIR}/settings.json`);
}
if (BASH_CONFIRM_TEMPLATE) {
  stageFile(BASH_CONFIRM_TEMPLATE, `${AGENT_DIR}/bash-confirm.json`);
}
// The SDK resolves its agent dir from this env (auth.json, sessions/, …).
process.env.PI_CODING_AGENT_DIR = AGENT_DIR;
process.env.HOME = AGENT_DIR;

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

// A session id is always a randomUUID() we minted. Validating it before it
// builds filesystem paths closes a path-traversal hole on attach.sessionId.
const SESSION_ID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
function isSessionId(value: string): boolean {
  return SESSION_ID_RE.test(value);
}

// ---- model registry (local llama-swap provider, design §4.2) --------------

const authStorage = AuthStorage.create(`${AGENT_DIR}/auth.json`);
authStorage.setRuntimeApiKey("local", LLAMA_SWAP_KEY);
// OpenRouter is a built-in provider: setting its key surfaces its whole model
// catalog in getAvailable() next to the local llama-swap provider, so clients
// pick OpenRouter models from the same picker.
if (OPENROUTER_KEY) authStorage.setRuntimeApiKey("openrouter", OPENROUTER_KEY);
const modelRegistry = ModelRegistry.create(
  authStorage,
  `${AGENT_DIR}/models.json`,
);

interface ProviderModel {
  id: string;
  name: string;
  reasoning: boolean;
  input: ["text", "image"];
  cost: { input: 0; output: 0; cacheRead: 0; cacheWrite: 0 };
  contextWindow: number;
  maxTokens: number;
}
function providerModel(id: string, ctx = 128000, max = 4096): ProviderModel {
  return {
    id,
    name: id,
    reasoning: false,
    // Optimistic vision declaration: llama-swap exposes no vision metadata,
    // and pi-ai silently downgrades image parts to "(image omitted…)" for
    // models that don't declare "image" input — which would drop every panel
    // attachment. A non-vision model just errors that one request instead.
    input: ["text", "image"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: ctx,
    maxTokens: max,
  };
}

// Mirror the bundled llama-swap-discover extension: GET ${LLM_URL}/v1/models and
// register them as provider "local" (api "openai-completions"). Falls back to
// the configured DEFAULT_MODEL if discovery yields nothing (offline tests).
async function setupProvider(): Promise<void> {
  const baseUrl = `${LLM_URL.replace(/\/+$/, "")}/v1`;
  let models: ProviderModel[] = [];
  try {
    models = (await fetchModels(LLM_URL, LLAMA_SWAP_KEY)).map((m) =>
      providerModel(m.id, m.contextLength, m.maxTokens),
    );
  } catch (err) {
    console.error("pi-sessiond: model discovery failed:", err);
  }
  if (models.length === 0 && DEFAULT_MODEL)
    models = [providerModel(DEFAULT_MODEL)];
  // No models (unconfigured / discovery offline): still start, just can't create
  // sessions — registerProvider rejects an empty model list.
  if (models.length === 0) {
    console.error(
      "pi-sessiond: no models discovered; provider 'local' not registered",
    );
    return;
  }
  modelRegistry.registerProvider("local", {
    baseUrl,
    apiKey: LLAMA_SWAP_KEY,
    api: "openai-completions",
    compat: { supportsDeveloperRole: false, supportsReasoningEffort: false },
    models,
  });
}

// ---- connection + session state -------------------------------------------

interface ConnData {
  id: string;
  authed: boolean;
  // Per-connection envelope pipeline. WebSocket framing delivers messages
  // in order; this chain makes the daemon PROCESS them in order too. A
  // client pipelines `attach` + commands on one socket — if the commands
  // dispatched concurrently while the attach awaited a cold resume, they'd
  // look up an id that isn't registered yet and bounce with "no such
  // session" (seen in production as a model-less session after a daemon
  // restart). Cross-connection concurrency is untouched.
  queue: Promise<void>;
}
type Conn = ServerWebSocket<ConnData>;

interface BufferedEvent {
  seq: number;
  data: string;
}
const BUFFER_CAP = 4096;

interface Session {
  id: string;
  name: string; // display label (create_session.name); "" if unnamed
  driver: RpcDriver;
  seq: number;
  subscribers: Set<Conn>;
  buffer: BufferedEvent[];
  busy: boolean; // mid-turn (agent_start..agent_end); never GC a busy session
  parked: boolean; // blocked on a human (§6); never GC a parked session
  lastActivity: number; // epoch ms of last event/command; drives idle-GC + LRU
  // Open side-channel requests (id -> method) awaiting an answer; used to dedupe
  // responses first-answer-wins and to drive the parked state.
  pendingSidechannels: Map<string, string>;
  // id -> relay the panel's answer to the child as an extension_ui_response.
  resolvers: Map<string, (response: Record<string, unknown>) => void>;
}
const sessions = new Map<string, Session>();
// All authenticated websockets, regardless of which session(s) they're
// attached to. The session-list is a per-executor concern (not per-session),
// so broadcasts of `kind: "sessions"` (design §12) fan out over this set —
// not per-session `subscribers`. A conn lands here on a valid `hello`, leaves
// on socket close.
const authedConns = new Set<Conn>();

function send(ws: Conn, msg: unknown): void {
  ws.send(JSON.stringify(msg));
}

// A session-scoped envelope failed. Echo the offending sessionId so a
// client multiplexing many sessions over one socket can route the error
// to the right one (e.g. drop a stale persisted id and recreate).
function sendNoSuchSession(ws: Conn, sessionId: string): void {
  send(ws, {
    v: 1,
    kind: "error",
    error: "no such session",
    ...(sessionId ? { sessionId } : {}),
  });
}

// Stamp a session event with the next monotonic seq and fan it out verbatim.
function broadcast(session: Session, payload: unknown): void {
  session.lastActivity = Date.now();
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

// Push the current session list to every authenticated client. Called on the
// list-shaping transitions: a new session was created, a live session was
// disposed (live → cold), or a cold session was just reloaded (cold →
// live-idle). Idle browsers / panels get a live-updated tab strip without
// polling. State changes inside a turn (live-idle ↔ live-busy ↔ parked) do
// *not* broadcast here — the per-session event stream already covers those
// for attached clients, and rebroadcasting the whole list on every step
// would be chatty.
function broadcastSessionsList(): void {
  if (authedConns.size === 0) return;
  const data = JSON.stringify({
    v: 1,
    kind: "sessions",
    sessions: listSessions(),
  });
  for (const ws of authedConns) ws.send(data);
}

// ---- session paths & metadata ---------------------------------------------

function sessionDirOf(id: string): string {
  return `${STATE_DIR}/sessions/${id}`;
}
function workdirOf(id: string): string {
  return `${STATE_DIR}/workspaces/${id}`;
}
// Each Landlock session's own writable agent dir (HOME / PI_CODING_AGENT_DIR),
// nested under its session dir so the one rw grant on the session dir covers it
// and concurrent instances never share a writable HOME.
function agentDirOf(id: string): string {
  return `${sessionDirOf(id)}/agent`;
}
// Each session's private TMPDIR, nested under its session dir (so the one rw
// grant on sessions/<id> covers it, and chownTree reaches it in system scope).
// The host's shared /tmp is absent from the allowlist and thus denied; tools
// that ignore $TMPDIR and write /tmp/... would otherwise EACCES, so point them
// here instead (design §5.1).
function tmpDirOf(id: string): string {
  return `${sessionDirOf(id)}/tmp`;
}
// Seed a session's private agent dir with the static config. COPIED, not
// symlinked: pi's settings-manager and startup migration rewrite settings.json,
// and the store templates are 0444 — a symlink would EACCES. auth.json /
// models.json / *.lock pi creates here itself; the long-term memory store stays
// shared (granted separately in writeLandlockPolicy).
function seedAgentDir(id: string): string {
  const dir = agentDirOf(id);
  mkdirSync(dir, { recursive: true });
  if (SETTINGS_TEMPLATE) stageFile(SETTINGS_TEMPLATE, `${dir}/settings.json`);
  if (BASH_CONFIRM_TEMPLATE) {
    stageFile(BASH_CONFIRM_TEMPLATE, `${dir}/bash-confirm.json`);
  }
  return dir;
}
// Recursively chown a session's dir tree to the unit's uid/gid. System scope
// only: the root daemon creates these dirs root-owned, but the per-session unit
// runs as a fixed non-root uid that must own them to write. The daemon (root)
// still reads them back for the session list.
function chownTree(path: string, ids: { uid: number; gid: number }): void {
  chownSync(path, ids.uid, ids.gid);
  for (const entry of readdirSync(path, { withFileTypes: true })) {
    const child = `${path}/${entry.name}`;
    if (entry.isDirectory()) chownTree(child, ids);
    else chownSync(child, ids.uid, ids.gid);
  }
}
// The TCP port a base URL dials (explicit port, else the scheme default). Used
// to grant the child connect_tcp to its model endpoint(s) under Landlock.
function modelPort(url: string): number | undefined {
  if (!url) return undefined;
  try {
    const u = new URL(url);
    return u.port ? Number(u.port) : u.protocol === "https:" ? 443 : 80;
  } catch {
    return undefined;
  }
}
// The per-session landlockconfig policy (design §5). Deny-by-default, bucketed
// by path type so each grant matches its inode (sandbox.ts). The workspace + the
// session dir (which contains this session's private agent dir / HOME) are
// granted rw; the shared long-term memory store is added below. Written next to
// the session so the launcher (pre-exec, uid 1000) can read it.
function writeLandlockPolicy(id: string): string {
  const rwDirs = [workdirOf(id), sessionDirOf(id)];
  const rwFiles: string[] = [];
  const roDirs: string[] = [];
  const roFiles: string[] = [];
  // An allowed-path source ending in `.sock` is a unix socket (a file);
  // everything else is a directory the runtime reads/writes/lists. Splitting
  // them keeps directory rights off socket inodes (which would downgrade
  // enforcement).
  for (const b of ALLOWED_PATHS) {
    const isSocket = b.source.endsWith(".sock");
    if (b.mode === "rw") (isSocket ? rwFiles : rwDirs).push(b.source);
    else (isSocket ? roFiles : roDirs).push(b.source);
  }
  // The memory store (sediment) writes a sqlite db plus -wal/-shm siblings.
  const sedimentDb = process.env.SEDIMENT_DB;
  if (sedimentDb) rwDirs.push(dirname(sedimentDb));
  // Egress: the child dials the credential proxy (openrouter) and/or the local
  // llama-swap endpoint. Grant connect_tcp to whichever ports are configured.
  const connectPorts = [PROXY_PORT, modelPort(LLM_URL)].filter(
    (p): p is number => typeof p === "number",
  );

  const policy = buildLandlockPolicy({
    rwDirs,
    rwFiles,
    roDirs,
    roFiles,
    connectPorts,
  });
  mkdirSync(sessionDirOf(id), { recursive: true });
  const path = `${sessionDirOf(id)}/landlock.json`;
  writeFileSync(path, JSON.stringify(policy));
  return path;
}
// Sibling of the session dir (not inside it) so pi never sees the daemon's
// bookkeeping file in its session dir.
function metaPathOf(id: string): string {
  return `${STATE_DIR}/sessions/${id}.meta.json`;
}

// Persisted per-session metadata so a disposed/cold session can be reloaded with
// the right provider/model (and its display name) after GC or a daemon restart.
interface SessionMeta {
  provider: string;
  model: string;
  name: string;
}
function writeSessionMeta(id: string, meta: SessionMeta): void {
  writeFileSync(metaPathOf(id), JSON.stringify(meta));
}
function readSessionMeta(id: string): SessionMeta | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(metaPathOf(id), "utf8"));
  } catch {
    return undefined;
  }
  if (!isRecord(parsed)) return undefined;
  const provider = asString(parsed.provider);
  const model = asString(parsed.model);
  if (provider === undefined || model === undefined) return undefined;
  return { provider, model, name: asString(parsed.name) ?? "" };
}

// ---- side channels (extension_ui, design §6) -------------------------------

// Run the configured notifier for a parked request, so a zero-client session
// blocked on a human reaches the user out-of-band. Best-effort, fire-and-forget.
function fireNotifier(session: Session, method: string, title: string): void {
  if (NOTIFY_CMD.length === 0) return;
  const child = spawn(NOTIFY_CMD, [], {
    stdio: "ignore",
    detached: true,
    env: {
      ...process.env,
      SPACES_NOTIFY_SESSION_ID: session.id,
      SPACES_NOTIFY_SESSION_NAME: session.name,
      SPACES_NOTIFY_METHOD: method,
      SPACES_NOTIFY_TITLE: title,
      SPACES_NOTIFY_EXECUTOR: EXECUTOR_ID,
    },
  });
  child.on("error", () => {});
  child.unref();
}

// The child emitted an extension_ui_request over the rpc pipe. Methods that
// expect an answer (confirm/select/input/editor) surface to attached clients
// as the `extension_ui_request` event the panel renders — buffered like any
// event so a reconnecting client replays it — and park + notify when none are
// attached; the client's reply is relayed back to the child as an
// extension_ui_response (resolveSidechannel). notify reaches the user
// out-of-band when unattended. Other ui methods (status/widget/title) have no
// panel affordance and are dropped, matching the old terminal no-ops.
function surfaceSideChannel(session: Session, frame: RpcFrame): void {
  const id = asString(frame.id);
  const method = asString(frame.method);
  if (!id || !method) return;
  if (method === "notify") {
    if (session.subscribers.size === 0)
      fireNotifier(session, "notify", asString(frame.message) ?? "");
    else broadcast(session, frame);
    return;
  }
  if (
    method !== "confirm" &&
    method !== "select" &&
    method !== "input" &&
    method !== "editor"
  )
    return;
  session.pendingSidechannels.set(id, method);
  session.resolvers.set(id, (response) =>
    session.driver.send({ ...response, type: "extension_ui_response", id }),
  );
  broadcast(session, frame);
  if (session.subscribers.size === 0) {
    session.parked = true;
    fireNotifier(session, method, asString(frame.title) ?? "");
  }
}

// First-answer-wins: relay the first client's response to the child as the
// extension_ui_response it's awaiting, tell the other attached clients to
// collapse, and unpark. A later (lost-race) answer just collapses its prompt.
function resolveSidechannel(
  session: Session,
  from: Conn,
  id: string | undefined,
  response: Record<string, unknown>,
): void {
  if (id === undefined) return;
  const resolver = session.resolvers.get(id);
  if (!resolver || !session.pendingSidechannels.has(id)) {
    send(from, {
      v: 1,
      kind: "sidechannel_resolved",
      sessionId: session.id,
      id,
      by: "",
    });
    return;
  }
  session.pendingSidechannels.delete(id);
  session.resolvers.delete(id);
  if (session.pendingSidechannels.size === 0) session.parked = false;
  const resolved = JSON.stringify({
    v: 1,
    kind: "sidechannel_resolved",
    sessionId: session.id,
    id,
    by: from.data.id,
  });
  for (const other of session.subscribers) {
    if (other !== from) other.send(resolved);
  }
  resolver(response);
}

// ---- session lifecycle -----------------------------------------------------

function peekBusy(session: Session, ev: RpcFrame): void {
  if (ev.type === "agent_start") session.busy = true;
  else if (ev.type === "agent_end") session.busy = false;
}

// Build a Session around a freshly spawned pi rpc-mode child. The supervisor
// runs no model code: it spawns `pi --mode rpc` pinned to this session's
// session-dir/id and workspace, then drives it over the rpc pipe. --session-id
// creates the session jsonl when absent and resumes it when present, so one
// path serves both a fresh create and a cold reload. The event stream wires to
// the §12 broadcast; extension_ui requests surface as the side-channel. bash,
// the file tools, and extensions all run inside the child — wrapped in its
// per-session Landlock unit (sandbox.ts) — never in the supervisor.
function registerSession(
  id: string,
  name: string,
  provider: string,
  model: string,
): Session {
  const piArgv = [
    PI_BIN,
    "--mode",
    "rpc",
    "--session-dir",
    sessionDirOf(id),
    "--session-id",
    id,
    "--provider",
    provider,
  ];
  if (model.length > 0) piArgv.push("--model", model);
  if (name.length > 0) piArgv.push("--name", name);
  // Each session gets its own writable agent dir (HOME / PI_CODING_AGENT_DIR);
  // concurrent instances share no writable dir except the long-term memory store.
  const agentDir = seedAgentDir(id);
  // Private per-session scratch dir, created up front so it exists under the
  // session-dir grant (and gets chowned with the tree in system scope).
  const tmpDir = tmpDirOf(id);
  mkdirSync(tmpDir, { recursive: true });
  // The child's environment. The unit gets a FRESH env, so all the runtime needs
  // (agent dir, provider endpoint, memory store, skill plumbing) is set
  // explicitly and carried in via --setenv.
  const childEnv: Record<string, string> = {
    PI_CODING_AGENT_DIR: agentDir,
    HOME: agentDir,
    SPACES_SESSION_ID: id,
    // Private scratch under the session-dir grant; the host /tmp is denied.
    TMPDIR: tmpDir,
    // The child reaches OpenRouter only through the supervisor's injecting
    // proxy; it never sees the real key (openrouter-proxy extension reads this).
    ...(OPENROUTER_PROXY_URL ? { OPENROUTER_PROXY_URL } : {}),
    ...childPassthroughEnv(),
    ...SESSION_ENV,
  };
  // Wrap the child in its per-session Landlock unit (sandbox.ts): systemd-run
  // applies kernel + seccomp hardening, then pi-landlock-exec self-applies the
  // FS/net/IPC domain before exec'ing pi. The cheap checks point SYSTEMD_RUN
  // (and the launcher) at passthrough stubs, so this one argv path serves both.
  const unitName = `pi-session-${id}.service`;
  const policyPath = writeLandlockPolicy(id);
  // System scope (root daemon): the unit runs as a fixed non-root uid, so the
  // session's dirs — created root-owned above — must be chowned to it before the
  // unit can write them (the launcher also reads the policy as that uid). No-op
  // on the desktop user service, where the unit runs as the daemon's own uid.
  if (SESSION_IDS) {
    chownTree(sessionDirOf(id), SESSION_IDS);
    chownTree(workdirOf(id), SESSION_IDS);
  }
  const argv = buildLandlockUnitArgv(
    {
      systemdRun: SYSTEMD_RUN,
      landlockExec: LANDLOCK_EXEC,
      policyPath,
      unitName,
      workdir: workdirOf(id),
      memoryHigh: MEMORY_HIGH,
      env: childEnv,
      ...(SESSION_IDS ? { uid: SESSION_IDS.uid, gid: SESSION_IDS.gid } : {}),
    },
    piArgv,
  );
  const session: Session = {
    id,
    name,
    // Assigned immediately below; the driver's callbacks close over `session`,
    // so it must exist before the driver is constructed.
    driver: undefined as unknown as RpcDriver,
    seq: 0,
    subscribers: new Set(),
    buffer: [],
    busy: false,
    parked: false,
    lastActivity: Date.now(),
    pendingSidechannels: new Map(),
    resolvers: new Map(),
  };
  session.driver = new RpcDriver({
    argv,
    cwd: workdirOf(id),
    // systemd-run inherits the daemon env so `--user` reaches the user manager;
    // the unit itself gets a fresh env built from the --setenv list (childEnv).
    // The test stub likewise applies --setenv before exec'ing the child.
    env: undefined,
    onEvent: (frame) => {
      peekBusy(session, frame);
      broadcast(session, frame);
    },
    onExtensionUI: (frame) => surfaceSideChannel(session, frame),
    onExit: () => {
      session.busy = false;
      session.parked = false;
    },
  });
  sessions.set(id, session);
  return session;
}

// A brand-new session: mint an id, record its provider/model/name so it can be
// reloaded from disk later, and spawn its child (which creates the jsonl).
function createSession(provider: string, model: string, name: string): Session {
  enforceCeiling();
  const id = randomUUID();
  mkdirSync(sessionDirOf(id), { recursive: true });
  mkdirSync(workdirOf(id), { recursive: true });
  writeSessionMeta(id, { provider, model, name });
  return registerSession(id, name, provider, model);
}

// Reload a cold session from its committed jsonl (design §5.1: attach to cold).
// Spawning is synchronous, so concurrent attaches can't race a half-built
// session — the first lands it in `sessions` before the next is dispatched.
function resumeSession(id: string): Session | undefined {
  const live = sessions.get(id);
  if (live) return live;
  const meta = readSessionMeta(id);
  if (!meta) return undefined;
  mkdirSync(workdirOf(id), { recursive: true });
  return registerSession(id, meta.name, meta.provider, meta.model);
}

// ---- idle-GC + resident-session ceiling (design §5.1) ----------------------

function touch(session: Session): void {
  session.lastActivity = Date.now();
}

// Safe to dispose: no attached clients, not mid-turn, not parked on a human.
function isEvictable(session: Session): boolean {
  return session.subscribers.size === 0 && !session.busy && !session.parked;
}

// Stop a session's pi child; its committed jsonl persists, so the next attach
// reloads it (cold). Only ever called on idle sessions. The session's
// listSessions state flips from "live-idle" back to "cold"; siblings learn via
// the broadcast below.
function gcSession(session: Session): void {
  sessions.delete(session.id);
  void session.driver.stop();
  broadcastSessionsList();
}

function enforceCeiling(): void {
  if (MAX_LIVE <= 0) return;
  while (sessions.size >= MAX_LIVE) {
    let victim: Session | undefined;
    for (const s of sessions.values()) {
      if (!isEvictable(s)) continue;
      if (!victim || s.lastActivity < victim.lastActivity) victim = s;
    }
    if (!victim) break;
    gcSession(victim);
  }
}

function gcIdleSessions(): void {
  if (IDLE_TIMEOUT_MS <= 0) return;
  const now = Date.now();
  for (const session of sessions.values()) {
    if (isEvictable(session) && now - session.lastActivity > IDLE_TIMEOUT_MS) {
      gcSession(session);
    }
  }
}

// ---- session registry (list_sessions, design §12) --------------------------

type SessionState = "cold" | "live-idle" | "live-busy" | "parked";

interface SessionInfo {
  id: string;
  name: string;
  executor: string;
  state: SessionState;
  updated: number;
}

function liveState(session: Session): SessionState {
  if (session.parked) return "parked";
  return session.busy ? "live-busy" : "live-idle";
}

// Cold sessions: the meta sidecars on disk with no live AgentSession.
function coldSessionIds(): string[] {
  try {
    return readdirSync(`${STATE_DIR}/sessions`)
      .filter((f) => f.endsWith(".meta.json"))
      .map((f) => f.slice(0, -".meta.json".length))
      .filter(isSessionId);
  } catch {
    return [];
  }
}

function coldUpdatedMs(id: string): number {
  try {
    return statSync(sessionDirOf(id)).mtimeMs;
  } catch {
    return 0;
  }
}

function listSessions(): SessionInfo[] {
  const out: SessionInfo[] = [];
  for (const s of sessions.values()) {
    out.push({
      id: s.id,
      name: s.name,
      executor: EXECUTOR_ID,
      state: liveState(s),
      updated: s.lastActivity,
    });
  }
  for (const id of coldSessionIds()) {
    if (sessions.has(id)) continue;
    out.push({
      id,
      name: readSessionMeta(id)?.name ?? "",
      executor: EXECUTOR_ID,
      state: "cold",
      updated: coldUpdatedMs(id),
    });
  }
  return out;
}

// ---- command dispatch into the session -------------------------------------

// A pi-rpc `response` event (the shape the panel's _handleResponse consumes).
// `id` echoes the request id the client attached, so its _request promise
// resolves; broadcasts carry the requester's id too — other clients ignore
// ids they didn't mint.
function responsePayload(
  command: string,
  data: Record<string, unknown>,
  id?: string,
): Record<string, unknown> {
  const base: Record<string, unknown> = {
    type: "response",
    command,
    success: true,
    data,
  };
  if (id) base.id = id;
  return base;
}
// The matching failure shape — rejects the requester's _request promise.
function errorPayload(
  command: string,
  error: string,
  id?: string,
): Record<string, unknown> {
  const base: Record<string, unknown> = {
    type: "response",
    command,
    success: false,
    error,
  };
  if (id) base.id = id;
  return base;
}
// Send an event envelope to a single client (query replies; not buffered).
function sendEvent(ws: Conn, session: Session, payload: unknown): void {
  send(ws, {
    v: 1,
    kind: "event",
    sessionId: session.id,
    seq: session.seq,
    payload,
  });
}

// Route a §12 `command` payload (pi's own rpc command shape) to the session's
// pi child over the rpc pipe. prompt/abort/set_thinking forward fire-and-
// forget (their effects arrive as events); set_model/get_state/get_messages
// round-trip the child and relay a `response` the panel consumes; set_memory
// and get_available_models stay supervisor-side (a marker file and the curated
// registry). The optional `id` is echoed on the response so the panel's
// _request promises correlate.
async function dispatchCommand(
  session: Session,
  ws: Conn,
  payload: Record<string, unknown>,
): Promise<void> {
  const type = asString(payload.type);
  const reqId = asString(payload.id);
  switch (type) {
    case "prompt": {
      const command: RpcFrame = {
        type: "prompt",
        message: asString(payload.message) ?? "",
      };
      const streamingBehavior = asString(payload.streamingBehavior);
      if (streamingBehavior === "steer" || streamingBehavior === "followUp")
        command.streamingBehavior = streamingBehavior;
      // Image attachments arrive in pi's own rpc shape
      // ({ type: "image", data: <base64>, mimeType }); forward verbatim.
      if (Array.isArray(payload.images) && payload.images.length > 0)
        command.images = payload.images.filter(isRecord);
      const r = await session.driver.request(command);
      if (r.success === false)
        broadcast(session, {
          type: "error",
          error: asString(r.error) ?? "prompt failed",
        });
      return;
    }
    case "abort":
      session.driver.send({ type: "abort" });
      return;
    case "set_thinking":
      if (asString(payload.level))
        session.driver.send({
          type: "set_thinking_level",
          level: payload.level,
        });
      return;
    case "set_model": {
      const model = modelRegistry.find(
        asString(payload.provider) ?? DEFAULT_PROVIDER,
        asString(payload.modelId) ?? asString(payload.model) ?? "",
      );
      if (!model) {
        sendEvent(
          ws,
          session,
          errorPayload("set_model", "unknown model", reqId),
        );
        return;
      }
      const r = await session.driver.request({
        type: "set_model",
        provider: model.provider,
        modelId: model.id,
      });
      if (r.success === false) {
        sendEvent(
          ws,
          session,
          errorPayload(
            "set_model",
            asString(r.error) ?? "set_model failed",
            reqId,
          ),
        );
        return;
      }
      broadcast(
        session,
        responsePayload(
          "set_model",
          { provider: model.provider, id: model.id },
          reqId,
        ),
      );
      return;
    }
    case "set_memory": {
      // Per-session opt-out marker for the memory extension (file present →
      // disabled). The child's memory extension re-reads it via
      // ctx.sessionManager.getSessionDir() at every hook entry, so the flip
      // applies on the next prompt without restarting the child. Owned by the
      // supervisor: it is not an rpc command.
      const enabled = payload.enabled !== false;
      const marker = `${sessionDirOf(session.id)}/memory-off`;
      try {
        if (enabled) rmSync(marker, { force: true });
        else writeFileSync(marker, "");
      } catch (err) {
        sendEvent(ws, session, errorPayload("set_memory", String(err), reqId));
        return;
      }
      broadcast(session, responsePayload("set_memory", { enabled }, reqId));
      return;
    }
    case "get_state": {
      const r = await session.driver.request({ type: "get_state" });
      const state = isRecord(r.data) ? r.data : {};
      const model = isRecord(state.model) ? state.model : undefined;
      sendEvent(
        ws,
        session,
        responsePayload(
          "get_state",
          {
            model: model ? { provider: model.provider, id: model.id } : null,
            messageCount: state.messageCount ?? 0,
            isStreaming: state.isStreaming === true,
          },
          reqId,
        ),
      );
      return;
    }
    case "get_messages": {
      const r = await session.driver.request({ type: "get_messages" });
      const data = isRecord(r.data) ? r.data : {};
      sendEvent(
        ws,
        session,
        responsePayload(
          "get_messages",
          { messages: data.messages ?? [] },
          reqId,
        ),
      );
      return;
    }
    case "get_available_models":
      sendEvent(
        ws,
        session,
        responsePayload(
          "get_available_models",
          {
            models: modelRegistry
              .getAvailable()
              .map((m) => ({ provider: m.provider, id: m.id, name: m.name })),
          },
          reqId,
        ),
      );
      return;
    default:
      console.error(
        `pi-sessiond: ignoring unknown command type: ${type ?? "(none)"}`,
      );
  }
}

// ---- envelope dispatch -----------------------------------------------------

async function handleMessage(ws: Conn, text: string): Promise<void> {
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
    authedConns.add(ws);
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
      const name = asString(parsed.name) ?? "";
      const session = createSession(provider, model, name);
      session.subscribers.add(ws);
      send(ws, {
        v: 1,
        kind: "attached",
        sessionId: session.id,
        seq: session.seq,
        // Distinguishes a create ack from a plain attach ack: the client
        // resolves its pending-create FIFO only on created acks, so a
        // racing re-attach ack can't consume a create resolver and stamp
        // the wrong daemon id onto a session entry.
        created: true,
      });
      // Fan the new entry out to every authenticated client so siblings'
      // tab strips refresh without polling (design §12 "n:m clients").
      broadcastSessionsList();
      return;
    }
    case "list_sessions": {
      send(ws, { v: 1, kind: "sessions", sessions: listSessions() });
      return;
    }
    case "delete_session": {
      // End the session for good — dispose any live AgentSession, remove
      // the on-disk session.jsonl + meta sidecar + per-session workspace,
      // then broadcast the updated list so every attached client (the
      // requester included) drops its tab. Idempotent: deleting a missing
      // id is a no-op + an error reply for diagnostics.
      const sessionId = asString(parsed.sessionId) ?? "";
      if (!isSessionId(sessionId)) {
        sendNoSuchSession(ws, sessionId);
        return;
      }
      const live = sessions.get(sessionId);
      if (live) {
        sessions.delete(sessionId);
        if (live.busy) live.driver.send({ type: "abort" });
        try {
          await live.driver.stop();
        } catch {
          // best-effort; we're tearing the session down regardless
        }
      }
      // Each rm guards individually so a partial state still cleans up
      // whatever else is on disk. `force` swallows ENOENT — fine because
      // we're already in "make this go away" mode.
      try {
        rmSync(sessionDirOf(sessionId), { recursive: true, force: true });
      } catch {
        // ignore
      }
      try {
        rmSync(metaPathOf(sessionId), { force: true });
      } catch {
        // ignore
      }
      try {
        rmSync(workdirOf(sessionId), { recursive: true, force: true });
      } catch {
        // ignore
      }
      send(ws, { v: 1, kind: "deleted", sessionId });
      broadcastSessionsList();
      return;
    }
    case "attach": {
      const sessionId = asString(parsed.sessionId) ?? "";
      if (!isSessionId(sessionId)) {
        sendNoSuchSession(ws, sessionId);
        return;
      }
      const live = sessions.get(sessionId);
      const session = live ?? resumeSession(sessionId);
      if (!session) {
        sendNoSuchSession(ws, sessionId);
        return;
      }
      session.subscribers.add(ws);
      send(ws, {
        v: 1,
        kind: "attached",
        sessionId: session.id,
        seq: session.seq,
      });
      const lastSeq = asNumber(parsed.lastSeq) ?? 0;
      for (const ev of session.buffer) {
        if (ev.seq > lastSeq) ws.send(ev.data);
      }
      // Cold → live-idle is a list-shaping change: the session's state moves
      // from "cold" to "live-idle" for everyone else's view. Refresh siblings.
      if (!live) broadcastSessionsList();
      return;
    }
    case "detach": {
      const session = sessions.get(asString(parsed.sessionId) ?? "");
      session?.subscribers.delete(ws);
      if (session) touch(session);
      return;
    }
    case "command": {
      const sessionId = asString(parsed.sessionId) ?? "";
      const session = sessions.get(sessionId);
      if (!session) {
        sendNoSuchSession(ws, sessionId);
        return;
      }
      touch(session);
      const payload = parsed.payload;
      if (!isRecord(payload)) return;
      // Side-channel responses (confirm/input/…) resolve pi's pending uiContext
      // promise in-process (first-answer-wins); they are not session commands.
      if (asString(payload.type) === "extension_ui_response") {
        resolveSidechannel(session, ws, asString(payload.id), payload);
        return;
      }
      await dispatchCommand(session, ws, payload);
      return;
    }
    default:
      send(ws, {
        v: 1,
        kind: "error",
        error: `unknown kind: ${kind ?? "(none)"}`,
      });
  }
}

// Serve the PWA's static assets on plain GETs; the same port upgrades to the WS
// protocol. Unknown paths fall back to index.html (client-side routing).
function serveStatic(req: Request): Response {
  if (PWA_DIR.length === 0) {
    return new Response("pi-sessiond: websocket only", { status: 426 });
  }
  let pathname = decodeURIComponent(new URL(req.url).pathname);
  if (pathname === "/" || pathname === "") pathname = "/index.html";
  const full = resolve(PWA_DIR, `.${pathname}`);
  const inDir = full === PWA_DIR || full.startsWith(`${PWA_DIR}/`);
  const served =
    inDir && existsSync(full) && statSync(full).isFile()
      ? full
      : `${PWA_DIR}/index.html`;
  return new Response(Bun.file(served));
}

// ---- WebSocket server ------------------------------------------------------

await setupProvider();

Bun.serve<ConnData>({
  hostname: HOST,
  port: PORT,
  fetch(req, server) {
    if (
      server.upgrade(req, {
        data: { id: randomUUID(), authed: false, queue: Promise.resolve() },
      })
    ) {
      return undefined;
    }
    const pathname = new URL(req.url).pathname;
    if (pathname === "/executors") {
      // Topology discovery for PWA clients. Unauthenticated on purpose: the
      // list itself is not a secret (it's `agent-<name>.<meta.domain>` hosts
      // that clan PKI + dm-dns already publish across the mesh) — the shared
      // bearer token still gates every WS attach/command. Empty PEERS is a
      // valid clan-of-one; the caller treats it as a single-executor fleet.
      return Response.json({
        self: EXECUTOR_ID,
        executors: PEERS,
      });
    }
    return serveStatic(req);
  },
  websocket: {
    message(ws, message) {
      const text =
        typeof message === "string" ? message : message.toString("utf8");
      // Serialize per connection (see ConnData.queue). A handler that
      // throws must not silently swallow the envelope: answer with a
      // correlated error so the client can route the failure.
      ws.data.queue = ws.data.queue.then(() =>
        handleMessage(ws, text).catch((err) => {
          console.error("pi-sessiond: envelope failed:", err);
          let sessionId: string | undefined;
          try {
            const parsed = JSON.parse(text);
            if (isRecord(parsed)) sessionId = asString(parsed.sessionId);
          } catch {
            // unparseable text already got its "invalid json" reply
          }
          send(ws, {
            v: 1,
            kind: "error",
            error: "internal error",
            ...(sessionId ? { sessionId } : {}),
          });
        }),
      );
    },
    close(ws) {
      for (const session of sessions.values()) session.subscribers.delete(ws);
      authedConns.delete(ws);
    },
  },
});

if (IDLE_TIMEOUT_MS > 0) {
  setInterval(gcIdleSessions, GC_INTERVAL_MS);
}

console.error(
  `pi-sessiond: listening on ${HOST}:${PORT} (executor ${EXECUTOR_ID}); ` +
    `agentDir=${AGENT_DIR} models=${modelRegistry.getAvailable().length}`,
);
