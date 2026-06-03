// pi-web: a custom web client (PWA) for a pi-sessiond executor.
//
// Speaks the §12 WebSocket envelope protocol — the same one the quickshell
// panel uses — so a browser can attach a session and mirror it alongside the
// desktop panel (n:m). The conversation is folded by the pure reducer; this
// file owns the transport + the DOM.
//
// Served by the daemon itself (same origin), so the WS endpoint is this page's
// own host. The hello token is entered once and kept in localStorage.

import {
  type ChatState,
  emptyState,
  withConfirmAnswer,
  withPiEvent,
  withSidechannelResolved,
  withUserPrompt,
} from "./reducer";

type Envelope = Record<string, unknown>;
interface SessionInfo { id: string; name: string; state: string; updated: number }

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

function wsUrl(): string {
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  return `${proto}//${location.host}/`;
}

function num(v: unknown): number {
  return typeof v === "number" ? v : 0;
}
function str(v: unknown): string {
  return typeof v === "string" ? v : "";
}

class Client {
  private sock: WebSocket | null = null;
  private sessions: SessionInfo[] = [];
  private active = "";
  private lastSeq = 0; // highest event seq seen for the active session
  private pendingCreate = false;
  private state: ChatState = emptyState();

  constructor(private readonly token: string) {}

  connect(): void {
    this.setStatus("connecting…");
    const sock = new WebSocket(wsUrl());
    this.sock = sock;
    sock.onopen = () =>
      this.send({ v: 1, kind: "hello", token: this.token, client: { name: "pi-web" } });
    sock.onmessage = (e) => this.onMessage(String(e.data));
    sock.onclose = () => {
      this.setStatus("reconnecting…");
      setTimeout(() => this.connect(), 1000);
    };
    sock.onerror = () => sock.close();
  }

  private send(env: Envelope): void {
    if (this.sock && this.sock.readyState === WebSocket.OPEN) this.sock.send(JSON.stringify(env));
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
        this.setStatus("connected");
        this.send({ v: 1, kind: "list_sessions" });
        // Reconnect: re-attach the active session and replay only what we missed
        // (seq > lastSeq), so the conversation continues without duplication.
        if (this.active) {
          this.send({ v: 1, kind: "attach", sessionId: this.active, lastSeq: this.lastSeq });
        }
        break;
      case "sessions":
        this.sessions = (Array.isArray(msg.sessions) ? (msg.sessions as SessionInfo[]) : [])
          .slice()
          .sort((a, b) => num(b.updated) - num(a.updated));
        // First connect with no active session: jump into the most recent one
        // (so a phone mirrors the desktop's session), else open a fresh one.
        if (!this.active && !this.pendingCreate) {
          if (this.sessions.length > 0) this.attach(this.sessions[0].id);
          else this.create();
        }
        this.renderTabs();
        break;
      case "attached": {
        const sid = str(msg.sessionId);
        if (this.pendingCreate) {
          this.pendingCreate = false;
          // The created session post-dates the last list_sessions; add it so its
          // tab appears immediately (a later list_sessions refreshes the rest).
          if (!this.sessions.some((s) => s.id === sid)) {
            this.sessions = [
              { id: sid, name: "web", state: "live-idle", updated: Date.now() },
              ...this.sessions,
            ];
          }
          this.switchTo(sid);
        } else if (sid === this.active && num(msg.seq) < this.lastSeq) {
          // The session was resurrected (cold respawn → seq reset); rebuild it.
          this.lastSeq = num(msg.seq);
          this.state = emptyState();
          this.render();
        }
        break;
      }
      case "event":
        if (msg.sessionId === this.active) {
          this.lastSeq = num(msg.seq);
          this.state = withPiEvent(this.state, msg.payload);
          this.render();
        }
        break;
      case "sidechannel_resolved":
        if (msg.sessionId === this.active) {
          this.state = withSidechannelResolved(this.state, str(msg.id));
          this.render();
        }
        break;
      case "error":
        this.setStatus(`error: ${str(msg.error) || "unknown"}`);
        break;
      default:
        break;
    }
  }

  // Switch to (and replay from the start of) an existing session.
  attach(id: string): void {
    if (!id || id === this.active) return;
    this.switchTo(id);
    this.send({ v: 1, kind: "attach", sessionId: id, lastSeq: 0 });
  }

  create(): void {
    this.pendingCreate = true;
    this.send({ v: 1, kind: "create_session", name: "web" });
  }

  private switchTo(id: string): void {
    this.active = id;
    this.lastSeq = 0;
    this.state = emptyState();
    this.renderTabs();
    this.render();
  }

  sendPrompt(textValue: string): void {
    const text = textValue.trim();
    if (!text || !this.active) return;
    this.state = withUserPrompt(this.state, text);
    this.render();
    this.send({
      v: 1,
      kind: "command",
      sessionId: this.active,
      payload: { type: "prompt", message: text, streamingBehavior: "steer" },
    });
  }

  answerConfirm(id: string, allowed: boolean): void {
    this.state = withConfirmAnswer(this.state, id, allowed);
    this.render();
    this.send({
      v: 1,
      kind: "command",
      sessionId: this.active,
      payload: { type: "extension_ui_response", id, confirmed: allowed },
    });
  }

  private setStatus(s: string): void {
    $("#status").textContent = s;
  }

  private renderTabs(): void {
    const bar = $("#tabs");
    bar.replaceChildren();
    for (const s of this.sessions) {
      const tab = el("button", `tab${s.id === this.active ? " active" : ""}`, s.name || s.id.slice(0, 6));
      tab.onclick = () => this.attach(s.id);
      bar.append(tab);
    }
    const add = el("button", "tab new", "+");
    add.onclick = () => this.create();
    bar.append(add);
  }

  private render(): void {
    const log = $("#log");
    log.replaceChildren();
    for (const m of this.state.messages) {
      const row = el("div", `msg ${m.role}${m.streaming ? " streaming" : ""}`);
      row.append(el("div", "text", m.text));
      log.append(row);
    }
    for (const c of this.state.confirms) {
      const card = el("div", `confirm ${c.state}`);
      card.append(el("div", "title", c.title));
      if (c.state === "pending") {
        const deny = el("button", "deny", "Deny");
        const allow = el("button", "allow", "Allow");
        deny.onclick = () => this.answerConfirm(c.id, false);
        allow.onclick = () => this.answerConfirm(c.id, true);
        const row = el("div", "actions");
        row.append(deny, allow);
        card.append(row);
      } else {
        card.append(el("div", "outcome", c.state));
      }
      log.append(card);
    }
    if (this.state.typing) log.append(el("div", "typing", "…"));
    log.scrollTop = log.scrollHeight;
  }
}

function start(token: string): void {
  localStorage.setItem(TOKEN_KEY, token);
  $("#gate").style.display = "none";
  $("#app").style.display = "flex";
  const client = new Client(token);
  client.connect();
  const input = $("#input") as HTMLInputElement;
  const submit = () => {
    client.sendPrompt(input.value);
    input.value = "";
  };
  $("#send").onclick = submit;
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      submit();
    }
  });
}

function main(): void {
  const tokenInput = $("#token") as HTMLInputElement;
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
