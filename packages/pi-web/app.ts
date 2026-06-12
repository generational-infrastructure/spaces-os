// pi-web: a custom web client (PWA) for a pi-sessiond executor.
//
// Speaks the §12 WebSocket envelope protocol — the same one the quickshell
// panel uses — so a browser can attach a session and mirror it alongside the
// desktop panel (n:m). The conversation is folded by the pure reducer; this
// file owns the transport + the DOM.
//
// Served by the daemon itself (same origin), so the WS endpoint is this page's
// own host. The hello token is entered once and kept in localStorage.
//
// Visual language follows the Spaces OS design system (see /design/styles.css
// and docs/design-system/source/ in the repo). The DOM is a vanilla-TS translation
// of the PWA UI kit's two-screen flow: a chat list (with a machine rail per
// row, name + machine identity + preview) and a chat view (back · title ·
// runtime control · message list · compose). The full multi-machine fleet
// roster + "Where this runs" sheet from the kit are deferred — the daemon
// only serves one executor, so the runtime control is a labelled affordance
// pointing at that single machine for now.

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

// Single-machine identity: the host serving this PWA *is* the executor.
// When the WebSocket is open the chat is reachable; when it drops we render
// the offline banner and disable the composer (matching the design's
// "hard-disable composing when the home machine is unreachable" rule).
function machineName(): string {
  return location.hostname || "this machine";
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

class Client {
  private sock: WebSocket | null = null;
  private sessions: SessionInfo[] = [];
  private active = "";
  private lastSeq = 0; // highest event seq seen for the active session
  private pendingCreate = false;
  private state: ChatState = emptyState();
  // Per-session reducer state so the chat list previews stay accurate when
  // switching between chats and the active tab still gets the latest fold.
  private states: Map<string, ChatState> = new Map();
  private connected = false;

  constructor(private readonly token: string) {}

  connect(): void {
    this.setStatus("connecting…");
    const sock = new WebSocket(wsUrl());
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
      this.setStatus("reconnecting…");
      this.refreshReachability();
      setTimeout(() => this.connect(), 1000);
    };
    sock.onerror = () => sock.close();
  }

  private send(env: Envelope): void {
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
        this.setStatus("connected");
        this.refreshReachability();
        this.send({ v: 1, kind: "list_sessions" });
        // Reconnect: re-attach the active session and replay only what we missed
        // (seq > lastSeq), so the conversation continues without duplication.
        if (this.active) {
          this.send({
            v: 1,
            kind: "attach",
            sessionId: this.active,
            lastSeq: this.lastSeq,
          });
        }
        break;
      case "sessions":
        this.sessions = (
          Array.isArray(msg.sessions) ? (msg.sessions as SessionInfo[]) : []
        )
          .slice()
          .sort((a, b) => num(b.updated) - num(a.updated));
        // If our previously-active session disappeared (deleted upstream by
        // another client, or by us via deleteSession), fall back the same
        // way the initial connect does: most recent surviving session, or
        // a freshly created one if the list is empty.
        const activeStillThere =
          !!this.active && this.sessions.some((s) => s.id === this.active);
        if (!activeStillThere) {
          this.active = "";
          this.state = emptyState();
          if (!this.pendingCreate) {
            if (this.sessions.length > 0) this.attach(this.sessions[0].id);
            else this.create();
          }
          this.renderChat();
        }
        this.renderList();
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
          this.viewChat();
        } else if (sid === this.active && num(msg.seq) < this.lastSeq) {
          // The session was resurrected (cold respawn → seq reset); rebuild it.
          this.lastSeq = num(msg.seq);
          this.state = emptyState();
          this.states.set(sid, this.state);
          this.renderChat();
        }
        break;
      }
      case "event":
        if (msg.sessionId === this.active) {
          this.lastSeq = num(msg.seq);
          this.state = withPiEvent(this.state, msg.payload);
          this.states.set(this.active, this.state);
          this.renderChat();
          this.renderList();
        }
        break;
      case "sidechannel_resolved":
        if (msg.sessionId === this.active) {
          this.state = withSidechannelResolved(this.state, str(msg.id));
          this.states.set(this.active, this.state);
          this.renderChat();
        }
        break;
      case "error":
        this.setStatus(`error: ${str(msg.error) || "unknown"}`, "error");
        break;
      default:
        break;
    }
  }

  // Switch to (and replay from the start of) an existing session, and surface
  // it in the chat view — opening the app drops the user in their most-recent
  // chat (Slack/iMessage pattern). The Back button is how they reach the list.
  attach(id: string): void {
    if (!id) return;
    if (id === this.active) {
      this.viewChat();
      return;
    }
    this.switchTo(id);
    this.send({ v: 1, kind: "attach", sessionId: id, lastSeq: 0 });
    this.viewChat();
  }

  create(): void {
    this.pendingCreate = true;
    this.send({ v: 1, kind: "create_session", name: "web" });
  }

  private switchTo(id: string): void {
    this.active = id;
    this.lastSeq = 0;
    this.state = this.states.get(id) ?? emptyState();
    this.states.set(id, this.state);
    this.renderList();
    this.renderChat();
  }

  sendPrompt(textValue: string): void {
    const text = textValue.trim();
    if (!text || !this.active || !this.connected) return;
    this.state = withUserPrompt(this.state, text);
    this.states.set(this.active, this.state);
    this.renderChat();
    this.send({
      v: 1,
      kind: "command",
      sessionId: this.active,
      payload: { type: "prompt", message: text, streamingBehavior: "steer" },
    });
  }

  answerConfirm(id: string, allowed: boolean): void {
    this.state = withConfirmAnswer(this.state, id, allowed);
    this.states.set(this.active, this.state);
    this.renderChat();
    this.send({
      v: 1,
      kind: "command",
      sessionId: this.active,
      payload: { type: "extension_ui_response", id, confirmed: allowed },
    });
  }

  deleteActive(): void {
    if (!this.active) return;
    const s = this.sessions.find((x) => x.id === this.active);
    const label = s?.name || this.active.slice(0, 6);
    this.deleteSession(this.active, label);
  }

  private deleteSession(id: string, label: string): void {
    if (
      !confirm(`Delete chat "${label}" and its history? This can't be undone.`)
    ) {
      return;
    }
    this.send({ v: 1, kind: "delete_session", sessionId: id });
  }

  private setStatus(text: string, tone: "default" | "error" = "default"): void {
    const node = $("#status");
    node.textContent = text;
    node.classList.toggle("connected", text === "connected");
    node.classList.toggle("error", tone === "error");
  }

  // Toggle the offline banner + composer state. Hard-disabling the composer
  // (no silent queue) matches the design system's offline rule.
  private refreshReachability(): void {
    const banner = $("#offline-banner") as HTMLElement;
    const input = $("#input") as HTMLInputElement;
    const send = $("#send") as HTMLButtonElement;
    const dot = $("#runtime-dot");
    if (this.connected) {
      banner.hidden = true;
      input.disabled = false;
      send.disabled = false;
      dot.classList.remove("offline");
      dot.classList.add("online");
    } else {
      $("#offline-machine").textContent = machineName();
      banner.hidden = false;
      input.disabled = true;
      send.disabled = true;
      dot.classList.remove("online");
      dot.classList.add("offline");
    }
  }

  // Two-view router. The chat list is the home; tapping a row opens that
  // chat. The back button returns to the list. We keep both DOM subtrees
  // mounted so `#input`/`#send`/`.tab.active` selectors stay reachable.
  viewList(): void {
    ($("#view-list") as HTMLElement).hidden = false;
    ($("#view-chat") as HTMLElement).hidden = true;
    // Tab title follows context: machine identity always trails so the user
    // can tell two pi-web tabs apart by executor at a glance.
    document.title = `Chats · ${machineName()}`;
  }
  viewChat(): void {
    if (!this.active) return;
    ($("#view-list") as HTMLElement).hidden = true;
    ($("#view-chat") as HTMLElement).hidden = false;
    this.renderChat();
    // Scroll the freshly-shown log to bottom on each entry.
    const log = $("#log");
    log.scrollTop = log.scrollHeight;
  }

  // ----- list view -----
  private renderList(): void {
    const list = $("#tabs");
    list.replaceChildren();
    if (this.sessions.length === 0) {
      const empty = el("li", "chat-empty", "No chats yet. Tap + to start one.");
      list.append(empty);
      return;
    }
    for (const s of this.sessions) {
      const isActive = s.id === this.active;
      const row = el("li", `tab${isActive ? " active" : ""}`);
      row.append(el("span", "machine-rail"));
      const body = el("div", "chat-row");
      const top = el("div", "chat-row-top");
      top.append(el("span", "chat-name", s.name || s.id.slice(0, 6)));
      top.append(el("span", "chat-machine", machineName()));
      top.append(el("span", "chat-time", fmtAgo(s.updated)));
      const bot = el("div", "chat-row-bottom");
      const st = this.states.get(s.id);
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
      }
      body.append(top, bot);
      row.append(body);
      row.onclick = () => this.attach(s.id);
      list.append(row);
    }
  }

  // ----- chat view -----
  private renderChat(): void {
    this.renderChatHead();
    this.renderRuntime();
    this.renderMessages();
  }

  // Chat-head title doubles as the document title so background tabs surface
  // the current chat name (matching the runtime pill's machine identity).
  private renderChatHead(): void {
    const s = this.sessions.find((x) => x.id === this.active);
    const name = s?.name || (this.active ? this.active.slice(0, 6) : "—");
    $("#chat-title").textContent = name;
    document.title = `${name} · ${machineName()}`;
  }

  private renderRuntime(): void {
    $("#runtime-mach").textContent = machineName();
    // No model id on SessionInfo today; the kit's "kiwi · qwen2.5-coder:14b"
    // collapses to just the machine for now (the separator hides when empty).
    $("#runtime-model").textContent = "";
    const sep = document.querySelector(".runtime-sep") as HTMLElement | null;
    if (sep) sep.style.visibility = "hidden";
  }

  private renderMessages(): void {
    const log = $("#log");
    log.replaceChildren();
    for (const m of this.state.messages) {
      const row = el("li", `msg ${m.role}${m.streaming ? " streaming" : ""}`);
      row.textContent = m.text;
      log.append(row);
    }
    for (const c of this.state.confirms) {
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
    if (this.state.typing) log.append(el("li", "typing", "thinking…"));
    log.scrollTop = log.scrollHeight;
  }
}

function start(token: string): void {
  localStorage.setItem(TOKEN_KEY, token);
  $("#gate").style.display = "none";
  $("#app").style.display = "flex";
  const client = new Client(token);
  client.connect();
  client.viewList();

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
    client.sendPrompt(input.value);
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
  $("#new-chat").onclick = () => client.create();
  $("#back").onclick = () => client.viewList();
  $("#chat-menu").onclick = () => client.deleteActive();
}

function main(): void {
  const tokenInput = $("#token") as HTMLInputElement;
  // Tab title starts as "pi · <host>" so even a fresh browser tab parked at
  // the gate is immediately distinguishable from other executors / other PWAs.
  document.title = `pi · ${machineName()}`;
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
