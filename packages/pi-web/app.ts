// pi-web: a custom web client (PWA) for the spaces-os pi-sessiond fleet.
//
// Speaks the §12 WebSocket envelope protocol — the same one the quickshell
// panel uses — so a browser can attach a session and mirror it alongside the
// desktop panel (n:m).
//
// Topology (mirrors the panel):
//
//   1. Loaded over HTTPS from any one executor (agent-<host>.<meta.domain>).
//   2. GET /executors (unauthenticated) lists every peer in the clan instance
//      with `webUi.enable = true`. The bearer token still gates every WS.
//   3. The PWA opens one WS to each peer (cross-origin, but the WS handshake
//      isn't subject to same-origin and the daemon doesn't validate Origin).
//      The hello token is the shared `pi-pi-sessiond-token` clan var, so the
//      user pastes it once and it works against every executor.
//   4. The chat list merges sessions across executors, each row tagged with
//      its executor's host. New chats prompt for the executor when the fleet
//      has more than one (single-executor clans skip the picker).
//
// State keying: every session is identified by (executorId, sessionId) — the
// pair is unique even if two executors mint colliding ids, and lets a chat
// know which conn to route its prompt/confirm against. The reducer fold is
// stored per-pair (only for sessions we've attached to in this tab session).

import {
  type ChatState,
  emptyState,
  withConfirmAnswer,
  withPiEvent,
  withSidechannelResolved,
  withUserPrompt,
} from "./reducer";

type Envelope = Record<string, unknown>;
interface SessionInfo {
  id: string;
  name: string;
  state: string;
  updated: number;
}
interface PeerEntry {
  id: string;
  host: string;
}
interface DiscoveryPayload {
  self: string;
  executors: PeerEntry[];
}

const TOKEN_KEY = "pi-web.token";

function $(sel: string): HTMLElement {
  const el = document.querySelector(sel);
  if (!el) throw new Error(`missing element: ${sel}`);
  return el as HTMLElement;
}

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  cls?: string,
  text?: string,
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined) node.textContent = text;
  return node;
}

function num(v: unknown): number {
  return typeof v === "number" ? v : 0;
}
function str(v: unknown): string {
  return typeof v === "string" ? v : "";
}

// Compose a `wss://` (or `ws://` in dev) URL for one executor. Same-origin
// peers reuse `location.host` (preserves the port the page was served on —
// matters in nix-sandbox tests where the daemon binds an ephemeral port);
// cross-origin peers go through Caddy on 443.
function wsUrl(host: string): string {
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  const target = host === location.hostname ? location.host : host;
  return `${proto}//${target}/`;
}

// "now" / "12m" / "3h" / "2d" — terse, lowercase, design-system voice.
function fmtAgo(t: number): string {
  if (!t) return "";
  const s = Math.max(0, Math.round((Date.now() - t) / 1000));
  if (s < 60) return "now";
  const m = Math.round(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.round(m / 60);
  if (h < 48) return `${h}h`;
  return `${Math.round(h / 24)}d`;
}

// First non-empty line of the latest message — what shows under the chat name
// in the list. Falls back to a placeholder so empty rows don't go silent.
function previewOf(state: ChatState): string {
  for (let i = state.messages.length - 1; i >= 0; i--) {
    const t = state.messages[i].text.trim();
    if (t) return t.split("\n", 1)[0];
  }
  const pending = state.confirms.find((c) => c.state === "pending");
  if (pending) return pending.title;
  return "—";
}

interface ActiveRef {
  executorId: string;
  sessionId: string;
}

// One WebSocket to one pi-sessiond. Owns its own session list, per-session
// reducer state, and reconnect loop. The Fleet calls `onUpdate` after any
// state change so the unified UI re-renders against the merged view.
class ExecutorConn {
  sock: WebSocket | null = null;
  connected = false;
  sessions: SessionInfo[] = [];
  // Per-session: highest seq seen (for replay-from-seq on reconnect) and the
  // folded ChatState. Maps survive ws drops; `connected` gates writes.
  lastSeq: Map<string, number> = new Map();
  states: Map<string, ChatState> = new Map();
  // Tracks the next-acked attached envelope so we know which freshly-created
  // session id belongs to the user's "+ new chat" tap.
  pendingCreate = false;

  constructor(
    readonly id: string,
    readonly host: string,
    private readonly token: string,
    private readonly onUpdate: (
      conn: ExecutorConn,
      kind:
        | "welcome"
        | "sessions"
        | "event"
        | "attached"
        | "sidechannel"
        | "error"
        | "close",
      payload?: unknown,
    ) => void,
  ) {}

  connect(): void {
    const sock = new WebSocket(wsUrl(this.host));
    this.sock = sock;
    sock.onopen = () =>
      this.send({
        v: 1,
        kind: "hello",
        token: this.token,
        client: { name: "pi-web" },
      });
    sock.onmessage = (e) => this.onMessage(String(e.data));
    sock.onclose = () => {
      this.connected = false;
      this.onUpdate(this, "close");
      setTimeout(() => this.connect(), 1000);
    };
    sock.onerror = () => sock.close();
  }

  send(env: Envelope): void {
    if (this.sock && this.sock.readyState === WebSocket.OPEN)
      this.sock.send(JSON.stringify(env));
  }

  private onMessage(text: string): void {
    let msg: Envelope;
    try {
      msg = JSON.parse(text) as Envelope;
    } catch {
      return;
    }
    switch (msg.kind) {
      case "welcome":
        this.connected = true;
        this.send({ v: 1, kind: "list_sessions" });
        // Reconnect: re-attach every session we had folded state for and replay
        // only what we missed (seq > lastSeq). The folded states stay live so
        // the conversation continues without duplication.
        for (const [sid, seq] of this.lastSeq.entries()) {
          this.send({ v: 1, kind: "attach", sessionId: sid, lastSeq: seq });
        }
        this.onUpdate(this, "welcome");
        break;
      case "sessions":
        this.sessions = (
          Array.isArray(msg.sessions) ? (msg.sessions as SessionInfo[]) : []
        )
          .slice()
          .sort((a, b) => num(b.updated) - num(a.updated));
        this.onUpdate(this, "sessions");
        break;
      case "attached": {
        const sid = str(msg.sessionId);
        const seq = num(msg.seq);
        if (this.pendingCreate) {
          this.pendingCreate = false;
          // Post-dates the last list_sessions; insert so the row appears
          // before the next list_sessions refresh arrives.
          if (!this.sessions.some((s) => s.id === sid)) {
            this.sessions = [
              { id: sid, name: "web", state: "live-idle", updated: Date.now() },
              ...this.sessions,
            ];
          }
          this.states.set(sid, emptyState());
          this.lastSeq.set(sid, 0);
          this.onUpdate(this, "attached", { sessionId: sid, fresh: true });
        } else {
          // Session was resurrected (cold respawn → seq reset); rebuild fold.
          const known = this.lastSeq.get(sid);
          if (known !== undefined && seq < known) {
            this.states.set(sid, emptyState());
            this.lastSeq.set(sid, seq);
            this.onUpdate(this, "attached", { sessionId: sid, fresh: false });
          }
        }
        break;
      }
      case "event": {
        const sid = str(msg.sessionId);
        const cur = this.states.get(sid) ?? emptyState();
        this.states.set(sid, withPiEvent(cur, msg.payload));
        this.lastSeq.set(sid, num(msg.seq));
        this.onUpdate(this, "event", { sessionId: sid });
        break;
      }
      case "sidechannel_resolved": {
        const sid = str(msg.sessionId);
        const cur = this.states.get(sid);
        if (cur) {
          this.states.set(sid, withSidechannelResolved(cur, str(msg.id)));
          this.onUpdate(this, "sidechannel", { sessionId: sid });
        }
        break;
      }
      case "error":
        this.onUpdate(this, "error", str(msg.error) || "unknown");
        break;
      default:
        break;
    }
  }

  attach(sessionId: string): void {
    if (!this.states.has(sessionId)) {
      this.states.set(sessionId, emptyState());
      this.lastSeq.set(sessionId, 0);
    }
    this.send({ v: 1, kind: "attach", sessionId, lastSeq: 0 });
  }

  create(): void {
    this.pendingCreate = true;
    this.send({ v: 1, kind: "create_session", name: "web" });
  }

  sendPrompt(sessionId: string, text: string): void {
    if (!this.connected) return;
    const cur = this.states.get(sessionId) ?? emptyState();
    this.states.set(sessionId, withUserPrompt(cur, text));
    this.onUpdate(this, "event", { sessionId, local: true });
    this.send({
      v: 1,
      kind: "command",
      sessionId,
      payload: { type: "prompt", message: text, streamingBehavior: "steer" },
    });
  }

  answerConfirm(sessionId: string, id: string, allowed: boolean): void {
    const cur = this.states.get(sessionId);
    if (!cur) return;
    this.states.set(sessionId, withConfirmAnswer(cur, id, allowed));
    this.onUpdate(this, "event", { sessionId, local: true });
    this.send({
      v: 1,
      kind: "command",
      sessionId,
      payload: { type: "extension_ui_response", id, confirmed: allowed },
    });
  }

  deleteSession(sessionId: string): void {
    this.send({ v: 1, kind: "delete_session", sessionId });
  }
}

class Fleet {
  // executorId → ExecutorConn. Insertion order = discovery order = render
  // order in the executor picker.
  private execs: Map<string, ExecutorConn> = new Map();
  private selfId = "";
  private active: ActiveRef | null = null;

  constructor(private readonly token: string) {}

  async start(): Promise<void> {
    // Discovery: ask the serving daemon who else is in the fleet. Falls back
    // to a single self-conn against the page origin if the endpoint is absent
    // (e.g., test sandbox with no PEERS) or returns an empty list.
    let peers: PeerEntry[] = [];
    let self = "local";
    try {
      const res = await fetch("/executors");
      if (res.ok) {
        const body = (await res.json()) as DiscoveryPayload;
        if (typeof body.self === "string") self = body.self;
        if (Array.isArray(body.executors)) {
          peers = body.executors.filter(
            (p) => p && typeof p.id === "string" && typeof p.host === "string",
          );
        }
      }
    } catch {
      // Ignore — fallback fills in.
    }
    if (peers.length === 0) {
      peers = [{ id: self, host: location.hostname || "127.0.0.1" }];
    }
    this.selfId = self;
    for (const peer of peers) {
      const conn = new ExecutorConn(peer.id, peer.host, this.token, (c, k, p) =>
        this.onConnUpdate(c, k, p),
      );
      this.execs.set(peer.id, conn);
      conn.connect();
    }
    this.viewList();
    this.refreshStatus();
  }

  // Aggregate dispatch from every ExecutorConn. The conn has already mutated
  // its own state; we just re-render and propagate cross-cutting concerns
  // (status pill, auto-attach on first welcome, offline banner).
  private onConnUpdate(
    conn: ExecutorConn,
    kind:
      | "welcome"
      | "sessions"
      | "event"
      | "attached"
      | "sidechannel"
      | "error"
      | "close",
    payload?: unknown,
  ): void {
    if (kind === "welcome") {
      // Eager auto-attach: pick the most-recent session across the whole
      // fleet on first welcome so the user lands in a real chat instead of
      // the empty-list view. Only fire if nothing is active yet.
      if (!this.active) this.autoLand();
    }
    if (kind === "attached") {
      const info = payload as { sessionId: string; fresh: boolean } | undefined;
      if (info?.fresh) {
        this.active = { executorId: conn.id, sessionId: info.sessionId };
        this.viewChat();
      }
    }
    if (kind === "error") {
      this.setStatus(`error: ${String(payload)}`, "error");
      return;
    }
    this.refreshStatus();
    this.renderList();
    if (this.active?.executorId === conn.id) this.renderChat();
  }

  // After every welcome, opportunistically land the user in a real chat if
  // one is available across the fleet. If not, create one on the local
  // executor (the one whose origin served the PWA).
  private autoLand(): void {
    let best: { execId: string; session: SessionInfo } | null = null;
    for (const conn of this.execs.values()) {
      for (const s of conn.sessions) {
        if (!best || s.updated > best.session.updated) {
          best = { execId: conn.id, session: s };
        }
      }
    }
    if (best) {
      this.attach(best.execId, best.session.id);
      return;
    }
    // No sessions anywhere → create one on the serving executor. Wait for
    // its WS to be ready (welcome already fired here, so it is).
    const home =
      this.execs.get(this.selfId) ?? this.execs.values().next().value;
    if (home && home.connected) home.create();
  }

  // ----- routing -----

  attach(executorId: string, sessionId: string): void {
    const conn = this.execs.get(executorId);
    if (!conn) return;
    const sameChat =
      this.active?.executorId === executorId &&
      this.active.sessionId === sessionId;
    this.active = { executorId, sessionId };
    if (!sameChat) conn.attach(sessionId);
    this.viewChat();
  }

  create(executorId: string): void {
    const conn = this.execs.get(executorId);
    if (!conn || !conn.connected) return;
    conn.create();
  }

  sendPrompt(text: string): void {
    if (!this.active) return;
    const trimmed = text.trim();
    if (!trimmed) return;
    const conn = this.execs.get(this.active.executorId);
    if (!conn || !conn.connected) return;
    conn.sendPrompt(this.active.sessionId, trimmed);
  }

  answerConfirm(id: string, allowed: boolean): void {
    if (!this.active) return;
    const conn = this.execs.get(this.active.executorId);
    if (!conn) return;
    conn.answerConfirm(this.active.sessionId, id, allowed);
  }

  deleteActive(): void {
    if (!this.active) return;
    const conn = this.execs.get(this.active.executorId);
    if (!conn) return;
    const sess = conn.sessions.find((s) => s.id === this.active!.sessionId);
    const label = sess?.name || this.active.sessionId.slice(0, 6);
    if (
      !confirm(`Delete chat "${label}" and its history? This can't be undone.`)
    ) {
      return;
    }
    conn.deleteSession(this.active.sessionId);
    this.active = null;
    this.viewList();
  }

  // ----- status / reachability -----

  private setStatus(text: string, tone: "default" | "error" = "default"): void {
    const node = $("#status");
    node.textContent = text;
    node.classList.toggle("connected", text === "connected");
    node.classList.toggle("error", tone === "error");
  }

  private refreshStatus(): void {
    const total = this.execs.size;
    const live = [...this.execs.values()].filter((c) => c.connected).length;
    if (live === 0) {
      this.setStatus("disconnected");
    } else if (live < total) {
      this.setStatus(`${live}/${total} online`);
    } else {
      this.setStatus("connected");
    }
    this.refreshReachability();
  }

  // Per-executor reachability drives the chat-view affordances. The "active
  // chat's executor is offline" case = banner shown + composer disabled.
  private refreshReachability(): void {
    const banner = $("#offline-banner") as HTMLElement;
    const input = $("#input") as HTMLInputElement;
    const send = $("#send") as HTMLButtonElement;
    const dot = $("#runtime-dot");
    const activeConn = this.active
      ? this.execs.get(this.active.executorId)
      : null;
    const reachable = !this.active || !!activeConn?.connected;
    if (reachable) {
      banner.hidden = true;
      input.disabled = false;
      send.disabled = false;
      dot.classList.remove("offline");
      dot.classList.add("online");
    } else {
      $("#offline-machine").textContent = activeConn?.host ?? "—";
      banner.hidden = false;
      input.disabled = true;
      send.disabled = true;
      dot.classList.remove("online");
      dot.classList.add("offline");
    }
  }

  // ----- view router (list ↔ chat) -----

  viewList(): void {
    ($("#view-list") as HTMLElement).hidden = false;
    ($("#view-chat") as HTMLElement).hidden = true;
    document.title = `Chats · ${location.hostname || "this machine"}`;
  }
  viewChat(): void {
    if (!this.active) return;
    ($("#view-list") as HTMLElement).hidden = true;
    ($("#view-chat") as HTMLElement).hidden = false;
    this.renderChat();
    const log = $("#log");
    log.scrollTop = log.scrollHeight;
  }

  // ----- list view -----

  renderList(): void {
    const list = $("#tabs");
    list.replaceChildren();
    // Merge sessions across all executors, tag each with its conn, sort by
    // updated. A clan-of-one collapses to one machine-host per row, same
    // visual rule the design system uses for fleet rendering.
    const rows: { conn: ExecutorConn; session: SessionInfo }[] = [];
    for (const conn of this.execs.values()) {
      for (const s of conn.sessions) rows.push({ conn, session: s });
    }
    rows.sort((a, b) => num(b.session.updated) - num(a.session.updated));
    if (rows.length === 0) {
      list.append(el("li", "chat-empty", "No chats yet. Tap + to start one."));
      return;
    }
    for (const { conn, session } of rows) {
      const isActive =
        this.active?.executorId === conn.id &&
        this.active.sessionId === session.id;
      const row = el("li", `tab${isActive ? " active" : ""}`);
      row.append(el("span", "machine-rail"));
      const body = el("div", "chat-row");
      const top = el("div", "chat-row-top");
      top.append(
        el("span", "chat-name", session.name || session.id.slice(0, 6)),
      );
      top.append(el("span", "chat-machine", conn.host));
      top.append(el("span", "chat-time", fmtAgo(session.updated)));
      const bot = el("div", "chat-row-bottom");
      const st = conn.states.get(session.id);
      bot.append(el("span", "chat-preview", st ? previewOf(st) : "—"));
      const pendingConfirm =
        !!st && st.confirms.some((c) => c.state === "pending");
      if (pendingConfirm) {
        bot.append(el("span", "chat-badge needs-you", "needs you"));
      } else if (st?.typing) {
        const b = el("span", "chat-badge working");
        b.append(el("span", "dot working"));
        b.append(document.createTextNode("working"));
        bot.append(b);
      } else if (!conn.connected) {
        bot.append(el("span", "chat-badge offline", "offline"));
      }
      body.append(top, bot);
      row.append(body);
      row.onclick = () => this.attach(conn.id, session.id);
      list.append(row);
    }
  }

  // ----- chat view -----

  renderChat(): void {
    this.renderChatHead();
    this.renderRuntime();
    this.renderMessages();
  }

  private activeSession(): {
    conn: ExecutorConn;
    session?: SessionInfo;
  } | null {
    if (!this.active) return null;
    const conn = this.execs.get(this.active.executorId);
    if (!conn) return null;
    return {
      conn,
      session: conn.sessions.find((s) => s.id === this.active!.sessionId),
    };
  }

  private renderChatHead(): void {
    const a = this.activeSession();
    const name =
      a?.session?.name ||
      (this.active ? this.active.sessionId.slice(0, 6) : "—");
    $("#chat-title").textContent = name;
    document.title = `${name} · ${location.hostname || "this machine"}`;
  }

  private renderRuntime(): void {
    const a = this.activeSession();
    $("#runtime-mach").textContent = a?.conn.host ?? "—";
    // Model id isn't on SessionInfo today; the kit's "kiwi · qwen2.5-coder:14b"
    // collapses to just the machine for now (the separator hides when empty).
    $("#runtime-model").textContent = "";
    const sep = document.querySelector(".runtime-sep") as HTMLElement | null;
    if (sep) sep.style.visibility = "hidden";
  }

  private renderMessages(): void {
    const log = $("#log");
    log.replaceChildren();
    const a = this.activeSession();
    if (!a) return;
    const state = a.conn.states.get(this.active!.sessionId) ?? emptyState();
    for (const m of state.messages) {
      const row = el("li", `msg ${m.role}${m.streaming ? " streaming" : ""}`);
      row.textContent = m.text;
      log.append(row);
    }
    for (const c of state.confirms) {
      const card = el("li", `confirm ${c.state}`);
      card.append(el("div", "title", c.title));
      if (c.state === "pending") {
        const actions = el("div", "actions");
        const deny = el("button", "deny", "Deny");
        const allow = el("button", "allow", "Allow");
        deny.onclick = () => this.answerConfirm(c.id, false);
        allow.onclick = () => this.answerConfirm(c.id, true);
        actions.append(deny, allow);
        card.append(actions);
      } else {
        const outcome = el("span", "outcome");
        if (c.state === "allowed") {
          outcome.append(el("span", "i i-check"));
          outcome.append(document.createTextNode("allowed"));
        } else if (c.state === "denied") {
          outcome.append(el("span", "i i-x"));
          outcome.append(document.createTextNode("denied"));
        } else {
          outcome.textContent = "resolved";
        }
        card.append(outcome);
      }
      log.append(card);
    }
    if (state.typing) log.append(el("li", "typing", "thinking…"));
    log.scrollTop = log.scrollHeight;
  }

  // ----- executor picker (for "+ new chat" when fleet has >1 executor) -----

  openCreatePicker(): void {
    const conns = [...this.execs.values()];
    if (conns.length === 1) {
      // Trivial fleet: skip the sheet entirely.
      this.create(conns[0].id);
      return;
    }
    const picker = $("#picker") as HTMLElement;
    const list = $("#picker-list");
    list.replaceChildren();
    for (const conn of conns) {
      const row = el("li", "picker-row");
      const dot = el("span", `dot ${conn.connected ? "online" : "offline"}`);
      const host = el("span", "picker-host", conn.host);
      const id = el("span", "picker-id", conn.id);
      row.append(dot, host, id);
      row.onclick = () => {
        picker.hidden = true;
        this.create(conn.id);
      };
      list.append(row);
    }
    picker.hidden = false;
  }
}

function start(token: string): void {
  localStorage.setItem(TOKEN_KEY, token);
  $("#gate").style.display = "none";
  $("#app").style.display = "flex";
  const fleet = new Fleet(token);
  void fleet.start();

  const input = $("#input") as HTMLInputElement;
  const send = $("#send") as HTMLButtonElement;
  // `send.disabled` only mirrors reachability (refreshReachability owns it).
  // The "empty input" state is purely cosmetic via a `.empty` class — DOM
  // `disabled` would block synthetic clicks from the e2e driver (which sets
  // `input.value` via assignment, bypassing the `input` event).
  const syncEmpty = (): void =>
    send.classList.toggle("empty", !input.value.trim());
  syncEmpty();

  const submit = (): void => {
    if (!input.value.trim()) return;
    fleet.sendPrompt(input.value);
    input.value = "";
    syncEmpty();
  };
  send.onclick = submit;
  input.addEventListener("input", syncEmpty);
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      submit();
    }
  });
  $("#new-chat").onclick = () => fleet.openCreatePicker();
  $("#back").onclick = () => fleet.viewList();
  $("#chat-menu").onclick = () => fleet.deleteActive();
  // Backdrop tap dismisses the picker; the inner sheet swallows its own clicks.
  const picker = $("#picker") as HTMLElement;
  picker.onclick = (e) => {
    if (e.target === picker) picker.hidden = true;
  };
}

function main(): void {
  const tokenInput = $("#token") as HTMLInputElement;
  // Tab title starts as "pi · <host>" so even a fresh browser tab parked at
  // the gate is immediately distinguishable from other executors / other PWAs.
  document.title = `pi · ${location.hostname || "this machine"}`;
  const saved = localStorage.getItem(TOKEN_KEY);
  if (saved) tokenInput.value = saved;
  $("#connect").onclick = () => start(tokenInput.value.trim());
  tokenInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") start(tokenInput.value.trim());
  });
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("/sw.js").catch(() => {});
  }
}

main();
