// The §12 envelope protocol (docs/remote-pi-design.md) as code — the normative
// artifact for the daemon ⇄ client wire. Everything pi-sessiond sends or
// receives over its WebSocket is one of these envelopes; the inner `payload`
// of command/event stays byte-for-byte pi's own rpc command/event protocol
// and is deliberately left `unknown` here.
//
// Consumers:
//   - main.ts (daemon): parseClientEnvelope on every inbound message, the
//     builder functions for every outbound envelope.
//   - packages/pi-web/app.ts (PWA): the same file, copied into the bundle's
//     src tree by pi-web/default.nix via a nix path reference — single source,
//     no second copy to keep in sync. It must therefore stay dependency-free.
//   - protocol-fixtures/*.json: the canonical frame corpus the python fake
//     daemons under checks/pi-session-* are held to (protocol.test.ts).
//
// Parsing is asymmetric on purpose:
//   - parseClientEnvelope is TOLERANT (wrong-typed optional fields degrade to
//     absent, sessionIds degrade to "") — matching the daemon's historical
//     robustness against half-formed clients; validity checks like "does this
//     session exist" stay with the caller.
//   - parseServerEnvelope is STRICT (required fields checked, v checked) —
//     the daemon is trusted, so anything that fails it is a protocol bug, and
//     the fixture conformance test uses it as the corpus validator.

export const PROTOCOL_VERSION = 1 as const;

// ---- session list (design §5.1) --------------------------------------------

export type SessionState = "cold" | "live-idle" | "live-busy" | "parked";

const SESSION_STATES: readonly SessionState[] = [
  "cold",
  "live-idle",
  "live-busy",
  "parked",
];

// One row of the executor's session list (`kind: "sessions"`). `executor` is
// the reporting executor's id — fleet clients key sessions by the
// (executor, id) pair.
export interface SessionInfo {
  id: string;
  name: string;
  executor: string;
  state: SessionState;
  updated: number;
}

// ---- client → server envelopes ---------------------------------------------

export interface HelloEnvelope {
  v: 1;
  kind: "hello";
  token?: string;
  client?: Record<string, unknown>;
}

export interface ListSessionsEnvelope {
  v: 1;
  kind: "list_sessions";
}

export interface CreateSessionEnvelope {
  v: 1;
  kind: "create_session";
  name?: string;
  provider?: string;
  model?: string;
  // Client-minted correlation id, echoed verbatim on the resulting attached
  // ack (and on an error ack if the create fails) so a client with several
  // in-flight creates routes each ack without FIFO guessing. Optional: the
  // uncorrelated flow keeps working for clients that don't send it.
  requestId?: string;
}

export interface AttachEnvelope {
  v: 1;
  kind: "attach";
  sessionId: string;
  lastSeq?: number;
}

export interface DetachEnvelope {
  v: 1;
  kind: "detach";
  sessionId: string;
}

export interface CommandEnvelope {
  v: 1;
  kind: "command";
  sessionId: string;
  // pi's own rpc command shape (prompt/abort/set_model/…), forwarded opaquely.
  payload?: Record<string, unknown>;
}

export interface DeleteSessionEnvelope {
  v: 1;
  kind: "delete_session";
  sessionId: string;
}

export type ClientEnvelope =
  | HelloEnvelope
  | ListSessionsEnvelope
  | CreateSessionEnvelope
  | AttachEnvelope
  | DetachEnvelope
  | CommandEnvelope
  | DeleteSessionEnvelope;

// ---- server → client envelopes ---------------------------------------------

export interface WelcomeEnvelope {
  v: 1;
  kind: "welcome";
  connectionId: string;
  caps: { executor?: string };
}

export interface SessionsEnvelope {
  v: 1;
  kind: "sessions";
  sessions: SessionInfo[];
}

export interface AttachedEnvelope {
  v: 1;
  kind: "attached";
  sessionId: string;
  seq: number;
  // Present (true) only on a create_session ack — clients resolve pending
  // creates only on created acks, so a racing re-attach ack can't be mistaken
  // for one.
  created?: true;
  // Echo of create_session.requestId, verbatim (correlated create ack).
  requestId?: string;
}

export interface EventEnvelope {
  v: 1;
  kind: "event";
  sessionId: string;
  seq: number;
  // pi's own typed event stream (agent_start/message_update/…), plus the
  // supervisor-minted `response` / `error` / `extension_ui_request` payloads.
  payload: unknown;
}

export interface SidechannelResolvedEnvelope {
  v: 1;
  kind: "sidechannel_resolved";
  sessionId: string;
  id: string;
  // connectionId of the client whose answer won; "" for a lost-race answer
  // (the entry was already claimed — collapse your prompt, nothing relayed).
  by: string;
}

export interface DeletedEnvelope {
  v: 1;
  kind: "deleted";
  sessionId: string;
}

export interface ErrorEnvelope {
  v: 1;
  kind: "error";
  error: string;
  // Echoed for session-scoped failures so a multiplexing client routes them.
  sessionId?: string;
  // Echoed when the failing request carried a create_session requestId.
  requestId?: string;
}

export type ServerEnvelope =
  | WelcomeEnvelope
  | SessionsEnvelope
  | AttachedEnvelope
  | EventEnvelope
  | SidechannelResolvedEnvelope
  | DeletedEnvelope
  | ErrorEnvelope;

// ---- parse / serialize -------------------------------------------------------

export type ParseResult<E> =
  | { ok: true; envelope: E }
  | {
      ok: false;
      error: string;
      // The JSON was a well-formed record but its `kind` is not part of the
      // protocol. The daemon answers these differently (auth-gated "unknown
      // kind" reply) from undecodable input.
      unknownKind?: true;
    };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}
function asNumber(value: unknown): number | undefined {
  return typeof value === "number" ? value : undefined;
}

export function serializeEnvelope(env: ClientEnvelope | ServerEnvelope): string {
  return JSON.stringify(env);
}

// Tolerant decode of a client's wire text (see the header note): unknown JSON
// shapes fail, but wrong-typed optional fields inside a known kind degrade
// instead of failing, mirroring how the daemon has always treated them.
export function parseClientEnvelope(
  text: string,
): ParseResult<ClientEnvelope> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return { ok: false, error: "invalid json" };
  }
  if (!isRecord(parsed)) return { ok: false, error: "invalid envelope" };
  const kind = asString(parsed.kind);
  const sessionId = asString(parsed.sessionId) ?? "";
  switch (kind) {
    case "hello": {
      const env: HelloEnvelope = { v: 1, kind };
      const token = asString(parsed.token);
      if (token !== undefined) env.token = token;
      if (isRecord(parsed.client)) env.client = parsed.client;
      return { ok: true, envelope: env };
    }
    case "list_sessions":
      return { ok: true, envelope: { v: 1, kind } };
    case "create_session": {
      const env: CreateSessionEnvelope = { v: 1, kind };
      const name = asString(parsed.name);
      const provider = asString(parsed.provider);
      const model = asString(parsed.model);
      const requestId = asString(parsed.requestId);
      if (name !== undefined) env.name = name;
      if (provider !== undefined) env.provider = provider;
      if (model !== undefined) env.model = model;
      if (requestId !== undefined) env.requestId = requestId;
      return { ok: true, envelope: env };
    }
    case "attach": {
      const env: AttachEnvelope = { v: 1, kind, sessionId };
      const lastSeq = asNumber(parsed.lastSeq);
      if (lastSeq !== undefined) env.lastSeq = lastSeq;
      return { ok: true, envelope: env };
    }
    case "detach":
      return { ok: true, envelope: { v: 1, kind, sessionId } };
    case "delete_session":
      return { ok: true, envelope: { v: 1, kind, sessionId } };
    case "command": {
      const env: CommandEnvelope = { v: 1, kind, sessionId };
      if (isRecord(parsed.payload)) env.payload = parsed.payload;
      return { ok: true, envelope: env };
    }
    default:
      return {
        ok: false,
        error: `unknown kind: ${kind ?? "(none)"}`,
        unknownKind: true,
      };
  }
}

function fail(kind: string, what: string): ParseResult<never> {
  return { ok: false, error: `${kind}: ${what}` };
}

function parseSessionInfo(value: unknown): SessionInfo | undefined {
  if (!isRecord(value)) return undefined;
  const id = asString(value.id);
  const name = asString(value.name);
  const executor = asString(value.executor);
  const state = asString(value.state) as SessionState | undefined;
  const updated = asNumber(value.updated);
  if (
    id === undefined ||
    name === undefined ||
    executor === undefined ||
    state === undefined ||
    !SESSION_STATES.includes(state) ||
    updated === undefined
  ) {
    return undefined;
  }
  return { id, name, executor, state, updated };
}

// Strict decode of a daemon's wire text (see the header note). Required
// fields missing or mistyped ⇒ failure with a field-naming error; this is
// also the corpus validator the fixture conformance test runs.
export function parseServerEnvelope(
  text: string,
): ParseResult<ServerEnvelope> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return { ok: false, error: "invalid json" };
  }
  if (!isRecord(parsed)) return { ok: false, error: "invalid envelope" };
  const kind = asString(parsed.kind) ?? "(none)";
  if (parsed.v !== PROTOCOL_VERSION) return fail(kind, "v must be 1");
  const sessionId = asString(parsed.sessionId);
  switch (kind) {
    case "welcome": {
      const connectionId = asString(parsed.connectionId);
      if (connectionId === undefined) return fail(kind, "connectionId");
      if (!isRecord(parsed.caps)) return fail(kind, "caps");
      const executor = asString(parsed.caps.executor);
      const caps: WelcomeEnvelope["caps"] =
        executor !== undefined ? { executor } : {};
      return { ok: true, envelope: { v: 1, kind, connectionId, caps } };
    }
    case "sessions": {
      if (!Array.isArray(parsed.sessions)) return fail(kind, "sessions");
      const sessions: SessionInfo[] = [];
      for (const entry of parsed.sessions) {
        const info = parseSessionInfo(entry);
        if (!info) return fail(kind, `bad entry: ${JSON.stringify(entry)}`);
        sessions.push(info);
      }
      return { ok: true, envelope: { v: 1, kind, sessions } };
    }
    case "attached": {
      const seq = asNumber(parsed.seq);
      if (sessionId === undefined) return fail(kind, "sessionId");
      if (seq === undefined) return fail(kind, "seq");
      const env: AttachedEnvelope = { v: 1, kind, sessionId, seq };
      if (parsed.created === true) env.created = true;
      const requestId = asString(parsed.requestId);
      if (requestId !== undefined) env.requestId = requestId;
      return { ok: true, envelope: env };
    }
    case "event": {
      const seq = asNumber(parsed.seq);
      if (sessionId === undefined) return fail(kind, "sessionId");
      if (seq === undefined) return fail(kind, "seq");
      return {
        ok: true,
        envelope: { v: 1, kind, sessionId, seq, payload: parsed.payload },
      };
    }
    case "sidechannel_resolved": {
      const id = asString(parsed.id);
      const by = asString(parsed.by);
      if (sessionId === undefined) return fail(kind, "sessionId");
      if (id === undefined) return fail(kind, "id");
      if (by === undefined) return fail(kind, "by");
      return { ok: true, envelope: { v: 1, kind, sessionId, id, by } };
    }
    case "deleted": {
      if (sessionId === undefined) return fail(kind, "sessionId");
      return { ok: true, envelope: { v: 1, kind, sessionId } };
    }
    case "error": {
      const error = asString(parsed.error);
      if (error === undefined) return fail(kind, "error");
      const env: ErrorEnvelope = { v: 1, kind, error };
      if (sessionId !== undefined) env.sessionId = sessionId;
      const requestId = asString(parsed.requestId);
      if (requestId !== undefined) env.requestId = requestId;
      return { ok: true, envelope: env };
    }
    default:
      return {
        ok: false,
        error: `unknown kind: ${kind}`,
        unknownKind: true,
      };
  }
}

// ---- builders (the daemon's outbound envelopes) ------------------------------

export function welcomeEnvelope(
  connectionId: string,
  executor: string,
): WelcomeEnvelope {
  return { v: 1, kind: "welcome", connectionId, caps: { executor } };
}

export function sessionsEnvelope(sessions: SessionInfo[]): SessionsEnvelope {
  return { v: 1, kind: "sessions", sessions };
}

export function attachedEnvelope(
  sessionId: string,
  seq: number,
  opts?: { created?: boolean; requestId?: string },
): AttachedEnvelope {
  const env: AttachedEnvelope = { v: 1, kind: "attached", sessionId, seq };
  if (opts?.created) env.created = true;
  if (opts?.requestId !== undefined) env.requestId = opts.requestId;
  return env;
}

export function eventEnvelope(
  sessionId: string,
  seq: number,
  payload: unknown,
): EventEnvelope {
  return { v: 1, kind: "event", sessionId, seq, payload };
}

export function sidechannelResolvedEnvelope(
  sessionId: string,
  id: string,
  by: string,
): SidechannelResolvedEnvelope {
  return { v: 1, kind: "sidechannel_resolved", sessionId, id, by };
}

export function deletedEnvelope(sessionId: string): DeletedEnvelope {
  return { v: 1, kind: "deleted", sessionId };
}

// sessionId/requestId are echoed only when non-empty: sendNoSuchSession has
// always omitted an empty offending id rather than sending sessionId: "".
export function errorEnvelope(
  error: string,
  opts?: { sessionId?: string; requestId?: string },
): ErrorEnvelope {
  const env: ErrorEnvelope = { v: 1, kind: "error", error };
  if (opts?.sessionId) env.sessionId = opts.sessionId;
  if (opts?.requestId) env.requestId = opts.requestId;
  return env;
}
