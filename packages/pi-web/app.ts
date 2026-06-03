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

class Client {
  private sock: WebSocket | null = null;
  private sessionId = "";
  private state: ChatState = emptyState();
  private status = "disconnected";

  constructor(private readonly token: string) {}

  connect(): void {
    this.setStatus("connecting…");
    const sock = new WebSocket(wsUrl());
    this.sock = sock;
    sock.onopen = () => this.send({ v: 1, kind: "hello", token: this.token, client: { name: "pi-web" } });
    sock.onmessage = (e) => this.onMessage(String(e.data));
    sock.onclose = () => {
      this.setStatus("disconnected — retrying…");
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
        // First connect: open a fresh session. (Session list / reattach: later.)
        if (!this.sessionId) this.send({ v: 1, kind: "create_session", name: "web" });
        else this.send({ v: 1, kind: "attach", sessionId: this.sessionId });
        break;
      case "attached":
        this.sessionId = String(msg.sessionId ?? "");
        break;
      case "event":
        if (msg.sessionId === this.sessionId) {
          this.state = withPiEvent(this.state, msg.payload);
          this.render();
        }
        break;
      case "sidechannel_resolved":
        this.state = withSidechannelResolved(this.state, String(msg.id ?? ""));
        this.render();
        break;
      case "error":
        this.setStatus(`error: ${String(msg.error ?? "unknown")}`);
        break;
      default:
        break;
    }
  }

  sendPrompt(textValue: string): void {
    const text = textValue.trim();
    if (!text || !this.sessionId) return;
    this.state = withUserPrompt(this.state, text);
    this.render();
    this.send({
      v: 1,
      kind: "command",
      sessionId: this.sessionId,
      payload: { type: "prompt", message: text, streamingBehavior: "steer" },
    });
  }

  answerConfirm(id: string, allowed: boolean): void {
    this.state = withConfirmAnswer(this.state, id, allowed);
    this.render();
    this.send({
      v: 1,
      kind: "command",
      sessionId: this.sessionId,
      payload: { type: "extension_ui_response", id, confirmed: allowed },
    });
  }

  private setStatus(s: string): void {
    this.status = s;
    $("#status").textContent = s;
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
  // Best-effort PWA installability; no-ops where service workers aren't allowed
  // (plain http on a non-localhost origin).
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("/sw.js").catch(() => {});
  }
}

main();
