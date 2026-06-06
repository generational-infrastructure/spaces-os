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
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { resolve } from "node:path";
import type { ServerWebSocket } from "bun";
import {
  type AgentSession,
  type AgentSessionEvent,
  AuthStorage,
  type BashOperations,
  createAgentSession,
  createBashToolDefinition,
  createEditToolDefinition,
  createReadToolDefinition,
  createWriteToolDefinition,
  DefaultResourceLoader,
  type ExtensionUIContext,
  ModelRegistry,
  SessionManager,
} from "@earendil-works/pi-coding-agent";
import { type BashSandboxConfig, buildBashSandboxArgv } from "./sandbox";

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
// systemd-run that confines each `bash` tool command (or a stub, in tests).
const SYSTEMD_RUN = process.env.SPACES_SESSIOND_SYSTEMD_RUN ?? "systemd-run";
const MEMORY_HIGH = process.env.SPACES_SESSIOND_MEMORY_HIGH ?? "4G";
// Trusted executor → skip filesystem narrowing (ProtectHome) for bash; the
// kernel/namespace hardening still applies. Default: untrusted (sandboxed).
const TRUSTED = (process.env.SPACES_SESSIOND_TRUSTED ?? "") === "1";
// A live-idle session with no attached clients is disposed after
// IDLE_TIMEOUT_MS (0 disables); MAX_LIVE caps resident sessions (0 = unlimited).
// Both rely on the SDK SessionManager reloading the jsonl on the next attach.
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

// Bundled pi extensions loaded into every session (e.g. bash-confirm, which
// drives the confirm side-channel). Colon-separated paths; the daemon does its
// own provider discovery, so llama-swap-discover is intentionally not here.
const EXTENSION_PATHS = (process.env.SPACES_SESSIOND_PI_EXTENSIONS ?? "")
  .split(":")
  .filter((p) => p.length > 0);

// One writable pi agent dir (HOME / PI_CODING_AGENT_DIR), seeded from the
// module's settings.json template. pi reads settings.json here and writes
// auth.json / sessions / *.lock back.
const AGENT_DIR = `${STATE_DIR}/pi-agent`;
mkdirSync(AGENT_DIR, { recursive: true });
mkdirSync(`${STATE_DIR}/sessions`, { recursive: true });
if (SETTINGS_TEMPLATE) {
  copyFileSync(SETTINGS_TEMPLATE, `${AGENT_DIR}/settings.json`);
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
authStorage.setRuntimeApiKey("local", "dummy");
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
  input: ["text"];
  cost: { input: 0; output: 0; cacheRead: 0; cacheWrite: 0 };
  contextWindow: number;
  maxTokens: number;
}
function providerModel(id: string, ctx = 128000, max = 4096): ProviderModel {
  return {
    id,
    name: id,
    reasoning: false,
    input: ["text"],
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
    const res = await fetch(`${baseUrl}/models`);
    if (res.ok) {
      const payload: unknown = await res.json();
      const data =
        isRecord(payload) && Array.isArray(payload.data) ? payload.data : [];
      models = data
        .filter(isRecord)
        .map((m) =>
          providerModel(
            asString(m.id) ?? "",
            asNumber(m.context_length) ?? asNumber(m.max_model_len) ?? 128000,
            asNumber(m.max_tokens) ?? 4096,
          ),
        )
        .filter((m) => m.id.length > 0);
    }
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
    apiKey: "dummy",
    api: "openai-completions",
    compat: { supportsDeveloperRole: false, supportsReasoningEffort: false },
    models,
  });
}

// Resolve a model for a session: the requested id, else the configured default,
// else the first available — inference lets us avoid annotating Model<…>.
function resolveModel(modelId: string) {
  return (
    (modelId ? modelRegistry.find(DEFAULT_PROVIDER, modelId) : undefined) ??
    (DEFAULT_MODEL
      ? modelRegistry.find(DEFAULT_PROVIDER, DEFAULT_MODEL)
      : undefined) ??
    modelRegistry.getAvailable()[0]
  );
}

// ---- connection + session state -------------------------------------------

interface ConnData {
  id: string;
  authed: boolean;
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
  agent: AgentSession;
  unsubscribe: () => void;
  seq: number;
  subscribers: Set<Conn>;
  buffer: BufferedEvent[];
  busy: boolean; // mid-turn (agent_start..agent_end); never GC a busy session
  parked: boolean; // blocked on a human (§6); never GC a parked session
  lastActivity: number; // epoch ms of last event/command; drives idle-GC + LRU
  // Open side-channel requests (id -> method) awaiting an answer; used to dedupe
  // responses first-answer-wins and to drive the parked state.
  pendingSidechannels: Map<string, string>;
  // id -> resolver for the in-process uiContext promise pi is awaiting.
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

// ---- sandboxed bash tool (design §8) ---------------------------------------

// BashOperations that run each command inside a `systemd-run` confinement unit
// (the bouquet from sandbox.ts). Output streams via onData; the AbortSignal and
// timeout kill the unit. In tests SYSTEMD_RUN is a stub that strips the flags
// and execs `bash -c <command>` directly.
function sandboxedBashOperations(sessionDir: string): BashOperations {
  return {
    exec(command, cwd, options) {
      const cfg: BashSandboxConfig = {
        systemdRun: SYSTEMD_RUN,
        workdir: cwd,
        agentDir: AGENT_DIR,
        memoryHigh: MEMORY_HIGH,
        trusted: TRUSTED,
        extraBinds: [sessionDir],
      };
      const argv = buildBashSandboxArgv(cfg, command);
      const { promise, resolve } = Promise.withResolvers<{
        exitCode: number | null;
      }>();
      const child = spawn(argv[0], argv.slice(1), {
        cwd,
        env: options.env ?? process.env,
      });
      const onAbort = () => child.kill("SIGTERM");
      options.signal?.addEventListener("abort", onAbort, { once: true });
      const timer =
        options.timeout && options.timeout > 0
          ? setTimeout(() => child.kill("SIGKILL"), options.timeout)
          : undefined;
      const finish = (exitCode: number | null) => {
        if (timer) clearTimeout(timer);
        options.signal?.removeEventListener("abort", onAbort);
        resolve({ exitCode });
      };
      child.stdout?.on("data", (d: Buffer) => options.onData(d));
      child.stderr?.on("data", (d: Buffer) => options.onData(d));
      child.on("error", () => finish(null));
      child.on("close", (code) => finish(code));
      return promise;
    },
  };
}

function buildTools(id: string) {
  const workdir = workdirOf(id);
  return [
    createBashToolDefinition(workdir, {
      operations: sandboxedBashOperations(sessionDirOf(id)),
    }),
    createReadToolDefinition(workdir),
    createEditToolDefinition(workdir),
    createWriteToolDefinition(workdir),
  ];
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

// pi (in-process) asked for a confirm/input/select/editor via uiContext. Mint an
// id, surface it to attached clients as an `extension_ui_request` event (or park
// + notify when none are attached), and return a promise pi awaits until a
// client answers (resolveSidechannel). First-answer-wins; a request is buffered
// like any event so a reconnecting client replays it.
function askSideChannel(
  session: Session,
  method: string,
  payload: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const id = randomUUID();
  const { promise, resolve } = Promise.withResolvers<Record<string, unknown>>();
  session.pendingSidechannels.set(id, method);
  session.resolvers.set(id, resolve);
  broadcast(session, { type: "extension_ui_request", id, method, ...payload });
  if (session.subscribers.size === 0) {
    session.parked = true;
    fireNotifier(session, method, asString(payload.title) ?? "");
  }
  return promise;
}

// First-answer-wins: resolve pi's pending uiContext promise with the first
// client's response, tell the other attached clients to collapse, and unpark.
// A later (lost-race) answer just collapses the sender's prompt.
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

// uiContext bound to a session: confirm/select/input/editor await a client; the
// rest are terminal-only no-ops (the daemon has no TUI).
function makeUiContext(session: Session): ExtensionUIContext {
  return {
    async confirm(title, message, opts) {
      const r = await askSideChannel(session, "confirm", {
        title,
        message,
        timeout: opts?.timeout,
      });
      return r.confirmed === true;
    },
    async select(title, options, opts) {
      const r = await askSideChannel(session, "select", {
        title,
        options,
        timeout: opts?.timeout,
      });
      return typeof r.value === "string" ? r.value : undefined;
    },
    async input(title, placeholder, opts) {
      const r = await askSideChannel(session, "input", {
        title,
        placeholder,
        timeout: opts?.timeout,
      });
      return typeof r.value === "string" ? r.value : undefined;
    },
    async editor(title, prefill) {
      const r = await askSideChannel(session, "editor", { title, prefill });
      return typeof r.value === "string" ? r.value : undefined;
    },
    notify(message, type) {
      if (session.subscribers.size === 0)
        fireNotifier(session, "notify", message);
      else
        broadcast(session, {
          type: "extension_ui_request",
          id: randomUUID(),
          method: "notify",
          message,
          notifyType: type,
        });
    },
    onTerminalInput() {
      return () => {};
    },
    setStatus() {},
    setWorkingMessage() {},
    setWorkingVisible() {},
    setWidget() {},
    setTitle() {},
    pasteToEditor() {},
    setEditorText() {},
    getEditorText() {
      return "";
    },
  };
}

// ---- session lifecycle -----------------------------------------------------

function peekBusy(session: Session, ev: AgentSessionEvent): void {
  if (ev.type === "agent_start") session.busy = true;
  else if (ev.type === "agent_end") session.busy = false;
}

// Build a Session around an SDK AgentSession (fresh or reloaded), wire its event
// stream to the §12 broadcast, and bind the side-channel uiContext.
async function registerSession(
  id: string,
  name: string,
  sessionManager: SessionManager,
  model: string,
): Promise<Session> {
  const resourceLoader = new DefaultResourceLoader({
    cwd: workdirOf(id),
    agentDir: AGENT_DIR,
    additionalExtensionPaths: EXTENSION_PATHS,
  });
  await resourceLoader.reload();
  const { session: agent } = await createAgentSession({
    agentDir: AGENT_DIR,
    cwd: workdirOf(id),
    authStorage,
    modelRegistry,
    model: resolveModel(model),
    sessionManager,
    resourceLoader,
    noTools: "builtin",
    customTools: buildTools(id),
  });
  const session: Session = {
    id,
    name,
    agent,
    unsubscribe: () => {},
    seq: 0,
    subscribers: new Set(),
    buffer: [],
    busy: false,
    parked: false,
    lastActivity: Date.now(),
    pendingSidechannels: new Map(),
    resolvers: new Map(),
  };
  session.unsubscribe = agent.subscribe((ev) => {
    peekBusy(session, ev);
    broadcast(session, ev);
  });
  await agent.bindExtensions({ uiContext: makeUiContext(session) });
  sessions.set(id, session);
  return session;
}

// A brand-new session: mint an id, create a fresh persisted session, and record
// its provider/model/name so it can be reloaded from disk later.
async function createSession(
  provider: string,
  model: string,
  name: string,
): Promise<Session> {
  enforceCeiling();
  const id = randomUUID();
  mkdirSync(sessionDirOf(id), { recursive: true });
  mkdirSync(workdirOf(id), { recursive: true });
  writeSessionMeta(id, { provider, model, name });
  const sm = SessionManager.create(workdirOf(id), sessionDirOf(id));
  return registerSession(id, name, sm, model);
}

// Reload a cold session from its committed jsonl (design §5.1: attach to cold).
// Returns undefined when nothing is persisted under this id.
async function resumeSession(id: string): Promise<Session | undefined> {
  const meta = readSessionMeta(id);
  if (!meta) return undefined;
  mkdirSync(workdirOf(id), { recursive: true });
  const sm = SessionManager.continueRecent(workdirOf(id), sessionDirOf(id));
  return registerSession(id, meta.name, sm, meta.model);
}

// ---- idle-GC + resident-session ceiling (design §5.1) ----------------------

function touch(session: Session): void {
  session.lastActivity = Date.now();
}

// Safe to dispose: no attached clients, not mid-turn, not parked on a human.
function isEvictable(session: Session): boolean {
  return session.subscribers.size === 0 && !session.busy && !session.parked;
}

// Dispose a session's in-process AgentSession; its committed jsonl persists, so
// the next attach reloads it (cold). Only ever called on idle sessions. The
// session's listSessions state flips from "live-idle" back to "cold"; siblings
// learn via the broadcast below.
function gcSession(session: Session): void {
  sessions.delete(session.id);
  session.unsubscribe();
  session.agent.dispose();
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
function responsePayload(
  command: string,
  data: Record<string, unknown>,
): Record<string, unknown> {
  return { type: "response", command, success: true, data };
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

// Route a §12 `command` payload (pi's own command shape) into the session.
// prompt/abort/set_model/set_thinking act; get_state / get_messages /
// get_available_models answer with a `response` event the panel consumes
// (queries reply to the requester; set_model broadcasts so mirrors update).
function dispatchCommand(
  session: Session,
  ws: Conn,
  payload: Record<string, unknown>,
): void {
  const type = asString(payload.type);
  switch (type) {
    case "prompt": {
      const message = asString(payload.message) ?? "";
      const streamingBehavior = asString(payload.streamingBehavior);
      const opts =
        streamingBehavior === "steer" || streamingBehavior === "followUp"
          ? { streamingBehavior }
          : undefined;
      void session.agent.prompt(message, opts).catch((err: unknown) => {
        broadcast(session, { type: "error", error: String(err) });
      });
      return;
    }
    case "abort":
      void session.agent.abort().catch(() => {});
      return;
    case "set_model": {
      const model = modelRegistry.find(
        asString(payload.provider) ?? DEFAULT_PROVIDER,
        asString(payload.modelId) ?? asString(payload.model) ?? "",
      );
      if (model) {
        void session.agent
          .setModel(model)
          .then(() =>
            broadcast(
              session,
              responsePayload("set_model", {
                provider: model.provider,
                id: model.id,
              }),
            ),
          )
          .catch((err: unknown) =>
            broadcast(session, { type: "error", error: String(err) }),
          );
      }
      return;
    }
    case "set_thinking": {
      const level = asString(payload.level);
      if (level)
        session.agent.setThinkingLevel(
          level as Parameters<AgentSession["setThinkingLevel"]>[0],
        );
      return;
    }
    case "get_state":
      sendEvent(
        ws,
        session,
        responsePayload("get_state", {
          model: session.agent.model
            ? {
                provider: session.agent.model.provider,
                id: session.agent.model.id,
              }
            : null,
          messageCount: session.agent.messages.length,
          isStreaming: session.agent.isStreaming,
        }),
      );
      return;
    case "get_messages":
      sendEvent(
        ws,
        session,
        responsePayload("get_messages", { messages: session.agent.messages }),
      );
      return;
    case "get_available_models":
      sendEvent(
        ws,
        session,
        responsePayload("get_available_models", {
          models: modelRegistry
            .getAvailable()
            .map((m) => ({ provider: m.provider, id: m.id, name: m.name })),
        }),
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
      const session = await createSession(provider, model, name);
      session.subscribers.add(ws);
      send(ws, {
        v: 1,
        kind: "attached",
        sessionId: session.id,
        seq: session.seq,
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
        send(ws, { v: 1, kind: "error", error: "no such session" });
        return;
      }
      const live = sessions.get(sessionId);
      if (live) {
        sessions.delete(sessionId);
        if (live.busy) {
          try {
            await live.agent.abort();
          } catch {
            // best-effort; we're tearing the session down regardless
          }
        }
        live.unsubscribe();
        try {
          live.agent.dispose();
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
        send(ws, { v: 1, kind: "error", error: "no such session" });
        return;
      }
      const live = sessions.get(sessionId);
      const session = live ?? (await resumeSession(sessionId));
      if (!session) {
        send(ws, { v: 1, kind: "error", error: "no such session" });
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
      const session = sessions.get(asString(parsed.sessionId) ?? "");
      if (!session) {
        send(ws, { v: 1, kind: "error", error: "no such session" });
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
      dispatchCommand(session, ws, payload);
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
    if (server.upgrade(req, { data: { id: randomUUID(), authed: false } })) {
      return undefined;
    }
    return serveStatic(req);
  },
  websocket: {
    message(ws, message) {
      void handleMessage(
        ws,
        typeof message === "string" ? message : message.toString("utf8"),
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
