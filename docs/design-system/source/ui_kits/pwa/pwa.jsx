// pi-chat PWA — phone client. Calmer redesign + reframed move UX.
//
// Move is NOT a buried "Move chat" wizard. A chat is a process on a
// machine, so "where it runs" is an editable property: the header's
// "running on kiwi" line IS the control. Tapping it opens "Where this
// runs" — one sheet unifying machine + model (+ memory on move). Same
// gesture as switching a model, because it's the same act.
const { useState, useEffect, useRef } = React;
const { Icon, StatusDot, MachineChip, Button, IconButton, Bubble, ConfirmCard, MACHINES } = window.SOS;

const SURFACE = "var(--m-surface)";
let _id = 200; const uid = () => "m" + (++_id);

function seedChats() {
  return [
    { id: "c1", name: "Fix deploy.sh", machine: "kiwi", model: "qwen2.5-coder:14b", lifecycle: "idle", needsYou: true, unread: 0, time: "3m",
      preview: "Run shell command? sed -i …", messages: [
        { id: uid(), from: "me", text: "scan deploy.sh for footguns", time: "5m", ack: "read" },
        { id: uid(), from: "peer", text: "Two issues: no `set -euo pipefail`, and the migration runs before the health check. Patch both?", time: "4m", tps: 47.9 },
        { id: uid(), from: "me", text: "yes, patch both", time: "3m", ack: "read", quote: "Patch both?" },
        { id: "cc1", type: "confirm", command: "sed -i '1i set -euo pipefail' deploy.sh", confirmState: "pending" },
      ] },
    { id: "c2", name: "Groceries", machine: "kiwi", model: "llama3.2:3b", lifecycle: "working", needsYou: false, unread: 2, time: "10m",
      preview: "Sheet-pan harissa chicken?", messages: [
        { id: uid(), from: "me", text: "add oat milk + a tuesday dinner idea", time: "12m", ack: "read" },
        { id: uid(), from: "peer", text: "Added oat milk. For Tuesday: sheet-pan harissa chicken?", time: "10m", tps: 61.0 },
      ] },
    { id: "c3", name: "Summarize refs", machine: "studio", model: "llama3.3:70b", lifecycle: "idle", needsYou: false, unread: 0, time: "1h",
      preview: "Pushed a synthesis to notes/…", messages: [
        { id: uid(), from: "me", text: "summarize the three papers in ~/refs", time: "1h", ack: "sent" },
        { id: uid(), from: "peer", text: "Pushed a synthesis to notes/synthesis.md.", time: "1h", tps: 18.4 },
      ] },
    { id: "c4", name: "Berlin trip", machine: "nas", model: "qwen2.5:7b", lifecycle: "idle", needsYou: false, unread: 0, time: "2h",
      preview: "Booked the 9:40 train.", messages: [
        { id: uid(), from: "me", text: "book the cheapest morning train to berlin", time: "2h", ack: "read" },
        { id: uid(), from: "peer", text: "Booked the 9:40 train — confirmation in your mail.", time: "2h", tps: 39.2 },
      ] },
  ];
}

function chatState(c) {
  if (MACHINES[c.machine].status === "offline") return "unreachable";
  if (c.needsYou) return "needs-you";
  if (c.lifecycle === "working") return "working";
  return "idle";
}

/* ============================ root ============================ */
function App() {
  const [chats, setChats] = useState(seedChats);
  const [view, setView] = useState({ name: "chats" });
  const [sheet, setSheet] = useState(null); // {type:'runon'|'where', chatId?}
  function patch(id, fn) { setChats(cs => cs.map(c => c.id === id ? fn(c) : c)); }

  return (
    <IOSDevice dark>
      <div style={{ height: "100%", position: "relative", overflow: "hidden", background: SURFACE, display: "flex", flexDirection: "column" }}>
        {view.name === "chats" && <ChatList chats={chats} onOpen={id => setView({ name: "chat", chatId: id })} onNew={() => setSheet({ type: "runon" })} />}
        {view.name === "machines" && <Machines chats={chats} />}
        {view.name === "chat" && <ChatView chat={chats.find(c => c.id === view.chatId)} patch={patch} onBack={() => setView({ name: "chats" })} onRuntime={id => setSheet({ type: "where", chatId: id })} />}

        {view.name !== "chat" && <TabBar view={view.name} setView={setView} />}

        {sheet?.type === "runon" && <RunOnSheet onClose={() => setSheet(null)}
          onPick={mk => { const id = "c" + Date.now(); const m = MACHINES[mk];
            setChats(cs => [{ id, name: "New chat", machine: mk, model: m.models[0], lifecycle: "idle", needsYou: false, unread: 0, time: "now", preview: "—", messages: [{ id: uid(), type: "notification", text: m.name + " · new session · " + m.models[0] }] }, ...cs]);
            setSheet(null); setView({ name: "chat", chatId: id }); }} />}
        {sheet?.type === "where" && <WhereSheet chat={chats.find(c => c.id === sheet.chatId)} onClose={() => setSheet(null)}
          onMove={tk => { const c = chats.find(x => x.id === sheet.chatId); const t = MACHINES[tk]; const nm = t.models.includes(c.model) ? c.model : t.models[0];
            patch(c.id, s => ({ ...s, machine: tk, model: nm, messages: [...s.messages, { id: uid(), type: "notification", text: "now running on " + t.name + " · " + nm }] })); }}
          onModel={model => patch(sheet.chatId, s => ({ ...s, model }))} />}
      </div>
    </IOSDevice>
  );
}

/* ============================ chat list (calm) ============================ */
function ChatList({ chats, onOpen, onNew }) {
  return (
    <>
      <div style={{ paddingTop: 56, paddingLeft: 20, paddingRight: 14, paddingBottom: 8, display: "flex", alignItems: "center" }}>
        <div style={{ flex: 1, font: "var(--weight-bold) var(--text-3xl)/1 var(--font-sans)", color: "var(--m-on-surface)", letterSpacing: "var(--tracking-tight)" }}>Chats</div>
        <IconButton icon="plus" size={38} title="New chat" onClick={onNew} />
      </div>
      <div style={{ flex: 1, overflowY: "auto", padding: "4px 12px 96px", display: "flex", flexDirection: "column" }}>
        {chats.map((c, i) => <ChatRow key={c.id} c={c} last={i === chats.length - 1} onOpen={() => onOpen(c.id)} />)}
      </div>
    </>
  );
}

function ChatRow({ c, last, onOpen }) {
  const m = MACHINES[c.machine];
  const state = chatState(c);
  const unreachable = state === "unreachable";
  const badge = <ChatBadge state={state} unread={c.unread} />;
  return (
    <button onClick={onOpen} style={{ width: "100%", textAlign: "left", display: "flex", gap: 12, alignItems: "stretch", padding: "13px 8px", background: "none", border: "none", borderBottom: last ? "none" : "var(--border-width) solid var(--m-outline)", cursor: "pointer", opacity: unreachable ? 0.55 : 1 }}>
      <div style={{ width: 3, alignSelf: "stretch", borderRadius: 2, background: m.color, flexShrink: 0 }} />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
          <span style={{ flex: 1, font: "var(--weight-bold) var(--text-m)/1.2 var(--font-sans)", color: "var(--m-on-surface)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{c.name}</span>
          <span style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)", color: m.color, flexShrink: 0 }}>{m.name}</span>
          <span style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)", color: "var(--m-on-surface-variant)", flexShrink: 0 }}>{c.time}</span>
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 5 }}>
          <span style={{ flex: 1, font: "var(--weight-medium) var(--text-s)/1.3 var(--font-sans)", color: "var(--m-on-surface-variant)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{c.preview}</span>
          {badge}
        </div>
      </div>
    </button>
  );
}

function ChatBadge({ state, unread }) {
  if (state === "needs-you")
    return <span style={{ display: "inline-flex", alignItems: "center", gap: 5, height: 19, padding: "0 8px", borderRadius: "var(--radius-xs)", background: "var(--m-primary)", color: "var(--m-on-primary)", font: "var(--weight-bold) var(--text-xs)/1 var(--font-sans)", flexShrink: 0 }}><Icon name="key" size={11} />needs you</span>;
  if (state === "working")
    return <span style={{ display: "inline-flex", alignItems: "center", gap: 5, font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)", color: "var(--m-primary)", flexShrink: 0 }}><StatusDot status="working" size={7} />working</span>;
  if (state === "unreachable")
    return <span style={{ display: "inline-flex", alignItems: "center", gap: 4, font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)", color: "var(--m-on-surface-variant)", flexShrink: 0 }}><Icon name="database-off" size={12} />offline</span>;
  if (unread > 0)
    return <span style={{ minWidth: 18, height: 18, padding: "0 5px", display: "inline-flex", alignItems: "center", justifyContent: "center", borderRadius: "var(--radius-xs)", background: "var(--m-primary)", color: "var(--m-on-primary)", font: "var(--weight-bold) var(--text-xs)/1 var(--font-sans)", flexShrink: 0 }}>{unread}</span>;
  return null;
}

/* ============================ chat view ============================ */
function ChatView({ chat, patch, onBack, onRuntime }) {
  const [draft, setDraft] = useState("");
  const listRef = useRef(null);
  const m = MACHINES[chat.machine];
  const reachable = m.status !== "offline";
  useEffect(() => { if (listRef.current) listRef.current.scrollTop = listRef.current.scrollHeight; }, [chat.messages.length]);

  function send() {
    if (!draft.trim() || !reachable) return;
    const text = draft.trim();
    patch(chat.id, c => ({ ...c, needsYou: false, messages: [...c.messages, { id: uid(), from: "me", text, time: "now", ack: "sent" }] }));
    setDraft("");
    setTimeout(() => patch(chat.id, c => ({ ...c, messages: [...c.messages, { id: uid(), from: "peer", text: "Got it — continuing on " + c.machine + ".", time: "now", tps: 45.0 }] })), 900);
  }
  function answer(id, ok) { patch(chat.id, c => ({ ...c, needsYou: false, messages: c.messages.map(x => x.id === id ? { ...x, confirmState: ok ? "allowed" : "denied" } : x) })); }

  return (
    <>
      <div style={{ paddingTop: 50, padding: "50px 10px 0", display: "flex", alignItems: "center", gap: 6 }}>
        <IconButton icon="chevron-up" size={34} title="Back" onClick={onBack} style={{ transform: "rotate(-90deg)" }} />
        <span style={{ flex: 1, minWidth: 0, font: "var(--weight-bold) var(--text-l)/1.15 var(--font-sans)", color: "var(--m-on-surface)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{chat.name}</span>
      </div>
      {/* runtime control — "where this runs" lives here; tap to move/switch model */}
      <button onClick={() => onRuntime(chat.id)} style={{ display: "flex", alignItems: "center", gap: 7, margin: "6px 12px 0", padding: "8px 12px", width: "calc(100% - 24px)", background: "var(--m-surface-variant)", border: "var(--border-width) solid var(--m-outline)", borderRadius: "var(--radius-input)", cursor: "pointer" }}>
        <StatusDot status={reachable ? "online" : "offline"} size={8} />
        <span style={{ font: "var(--weight-bold) var(--text-s)/1 var(--font-mono)", color: m.color, flexShrink: 0 }}>{m.name}</span>
        <span style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)", color: "var(--m-on-surface-variant)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>· {chat.model}</span>
        <span style={{ flex: 1 }} />
        <span style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)", color: "var(--m-secondary)", whiteSpace: "nowrap", flexShrink: 0 }}>Where it runs</span>
        <Icon name="chevron-down" size={14} color="var(--m-secondary)" />
      </button>

      <div ref={listRef} style={{ flex: 1, overflowY: "auto", display: "flex", flexDirection: "column", gap: "var(--space-m)", padding: "var(--space-m)" }}>
        {chat.messages.map(x => x.type === "confirm"
          ? <ConfirmCard key={x.id} command={x.command} state={x.confirmState} machine={{ name: m.name, color: m.color }} onAllow={() => answer(x.id, true)} onDeny={() => answer(x.id, false)} />
          : <Bubble key={x.id} from={x.from} text={x.text} time={x.time} ack={x.ack} tps={x.tps} quote={x.quote} variant={x.type === "notification" ? "notification" : x.type === "thinking" ? "thinking" : "text"} />)}
      </div>

      {!reachable ? (
        <div style={{ display: "flex", alignItems: "center", gap: 8, margin: "0 12px 26px", padding: "var(--space-m)", background: "var(--m-surface-variant)", border: "var(--border-width) solid var(--m-error)", borderRadius: "var(--radius-s)" }}>
          <Icon name="database-off" size={16} color="var(--m-error)" />
          <span style={{ font: "var(--weight-medium) var(--text-s)/1.4 var(--font-sans)", color: "var(--m-on-surface)" }}>Can’t reach <b style={{ fontFamily: "var(--font-mono)", color: m.color }}>{m.name}</b> — cached, read-only.</span>
        </div>
      ) : (
        <div style={{ display: "flex", alignItems: "flex-end", gap: 8, padding: "10px 12px 26px" }}>
          <div style={{ flex: 1, display: "flex", background: "var(--m-surface-variant)", border: "var(--border-width) solid var(--m-outline)", borderRadius: "var(--radius-input)" }}>
            <input value={draft} onChange={e => setDraft(e.target.value)} onKeyDown={e => { if (e.key === "Enter") { e.preventDefault(); send(); } }}
              placeholder={"Message " + m.name + "…"} style={{ width: "100%", background: "transparent", border: "none", outline: "none", color: "var(--m-on-surface)", font: "var(--weight-medium) var(--text-m)/1.2 var(--font-sans)", padding: "10px 14px" }} />
          </div>
          <IconButton icon="microphone" size={42} title="Voice" />
          <IconButton icon="send" size={42} title="Send" disabled={!draft.trim()} onClick={send} />
        </div>
      )}
    </>
  );
}

/* ============================ machines roster ============================ */
function Machines({ chats }) {
  return (
    <>
      <div style={{ paddingTop: 56, paddingLeft: 20, paddingRight: 16, paddingBottom: 10 }}>
        <div style={{ font: "var(--weight-bold) var(--text-3xl)/1 var(--font-sans)", color: "var(--m-on-surface)", letterSpacing: "var(--tracking-tight)" }}>Machines</div>
        <div style={{ font: "var(--weight-medium) var(--text-s)/1.3 var(--font-sans)", color: "var(--m-on-surface-variant)", marginTop: 4 }}>Where your agents actually run</div>
      </div>
      <div style={{ flex: 1, overflowY: "auto", padding: "4px 16px 96px", display: "flex", flexDirection: "column", gap: "var(--space-m)" }}>
        {Object.values(MACHINES).map(m => {
          const count = chats.filter(c => c.machine === m.name).length;
          const off = m.status === "offline";
          return (
            <div key={m.name} style={{ background: "var(--m-surface-variant)", border: "var(--border-width) solid " + (off ? "var(--m-outline)" : m.color), borderRadius: "var(--radius-s)", padding: "var(--space-m)", opacity: off ? 0.7 : 1 }}>
              <div style={{ display: "flex", alignItems: "center", gap: 10, whiteSpace: "nowrap" }}>
                <StatusDot status={m.status} size={12} />
                <span style={{ font: "var(--weight-bold) var(--text-xl)/1 var(--font-mono)", color: m.color, flexShrink: 0 }}>{m.name}</span>
                <span style={{ font: "var(--weight-medium) var(--text-s)/1 var(--font-sans)", color: "var(--m-on-surface-variant)", overflow: "hidden", textOverflow: "ellipsis", minWidth: 0 }}>{m.role}</span>
                <span style={{ flex: 1 }} />
                <span style={{ font: "var(--weight-semibold) var(--text-xs)/1 var(--font-sans)", color: off ? "var(--m-error)" : "var(--m-tertiary)", flexShrink: 0 }}>{off ? "offline" : (m.relayed ? "online · relayed" : "online · direct")}</span>
              </div>
              <div style={{ display: "flex", gap: 18, marginTop: 12 }}>
                <Stat label="chats" value={count} />
                <Stat label="models" value={m.models.length} />
                <Stat label="default" value={m.name === "kiwi" ? "yes" : "—"} />
              </div>
              <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginTop: 12 }}>
                {m.models.map(mod => <span key={mod} style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)", color: "var(--m-on-surface)", background: "var(--m-surface)", border: "var(--border-width) solid var(--m-outline)", borderRadius: "var(--radius-xs)", padding: "5px 8px" }}>{mod}</span>)}
              </div>
            </div>
          );
        })}
      </div>
    </>
  );
}

function Stat({ label, value }) {
  return (
    <div>
      <div style={{ font: "var(--weight-bold) var(--text-l)/1 var(--font-sans)", color: "var(--m-on-surface)" }}>{value}</div>
      <div style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)", color: "var(--m-on-surface-variant)", marginTop: 3 }}>{label}</div>
    </div>
  );
}

/* ============================ tab bar ============================ */
function TabBar({ view, setView }) {
  const tab = (name, icon, label) => {
    const on = view === name;
    return (
      <button onClick={() => setView({ name })} style={{ flex: 1, display: "flex", flexDirection: "column", alignItems: "center", gap: 3, background: "none", border: "none", cursor: "pointer", padding: "8px 0" }}>
        <Icon name={icon} size={22} color={on ? "var(--m-primary)" : "var(--m-on-surface-variant)"} />
        <span style={{ font: (on ? "var(--weight-semibold)" : "var(--weight-medium)") + " var(--text-xs)/1 var(--font-sans)", color: on ? "var(--m-primary)" : "var(--m-on-surface-variant)" }}>{label}</span>
      </button>
    );
  };
  return (
    <div style={{ position: "absolute", left: 0, right: 0, bottom: 0, paddingBottom: 22, display: "flex", background: "rgba(7,7,34,0.82)", backdropFilter: "blur(12px)", borderTop: "var(--border-width) solid var(--m-outline)", zIndex: 8 }}>
      {tab("chats", "message-chatbot", "Chats")}
      {tab("machines", "gauge", "Machines")}
    </div>
  );
}

/* ============================ bottom sheets ============================ */
function BottomSheet({ onClose, children }) {
  return (
    <div onClick={onClose} style={{ position: "absolute", inset: 0, background: "rgba(4,4,15,0.7)", backdropFilter: "blur(3px)", display: "flex", alignItems: "flex-end", zIndex: 40 }}>
      <div onClick={e => e.stopPropagation()} style={{ width: "100%", background: SURFACE, borderTopLeftRadius: 12, borderTopRightRadius: 12, border: "var(--border-width) solid var(--m-outline)", borderBottom: "none", paddingBottom: 30, maxHeight: "84%", overflowY: "auto" }}>
        <div style={{ width: 38, height: 4, borderRadius: 2, background: "var(--m-outline)", margin: "10px auto 4px" }} />
        {children}
      </div>
    </div>
  );
}

function SheetHead({ title, sub }) {
  return (
    <div style={{ padding: "10px 18px 14px" }}>
      <span style={{ font: "var(--weight-bold) var(--text-xl)/1.15 var(--font-sans)", color: "var(--m-on-surface)" }}>{title}</span>
      {sub ? <div style={{ font: "var(--weight-medium) var(--text-s)/1.45 var(--font-sans)", color: "var(--m-on-surface-variant)", marginTop: 6 }}>{sub}</div> : null}
    </div>
  );
}

function RunOnSheet({ onClose, onPick }) {
  return (
    <BottomSheet onClose={onClose}>
      <SheetHead title="Start a chat" sub="Pick the machine that will run the agent." />
      {Object.values(MACHINES).map(m => {
        const off = m.status === "offline";
        return (
          <div key={m.name} onClick={off ? undefined : () => onPick(m.name)} style={{ display: "flex", alignItems: "center", gap: 12, padding: "13px 18px", borderTop: "var(--border-width) solid var(--m-outline)", cursor: off ? "default" : "pointer", opacity: off ? 0.5 : 1 }}>
            <StatusDot status={m.status} size={11} />
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ display: "flex", alignItems: "center", gap: 8, whiteSpace: "nowrap" }}>
                <span style={{ font: "var(--weight-bold) var(--text-m)/1 var(--font-mono)", color: m.color }}>{m.name}</span>
                <span style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)", color: "var(--m-on-surface-variant)" }}>{m.role}</span>
              </div>
              <div style={{ font: "var(--weight-medium) var(--text-xs)/1.4 var(--font-mono)", color: off ? "var(--m-error)" : "var(--m-on-surface-variant)", marginTop: 4, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{off ? "unreachable" : m.models.join(" · ")}</div>
            </div>
            {!off ? <Icon name="chevron-up" size={16} color="var(--m-on-surface-variant)" style={{ transform: "rotate(90deg)" }} /> : null}
          </div>
        );
      })}
    </BottomSheet>
  );
}

/* "Where this runs" — the reframed move: machine + model in one place. */
function WhereSheet({ chat, onClose, onMove, onModel }) {
  const [mem, setMem] = useState(false);
  const cur = MACHINES[chat.machine];
  const sourceReachable = cur.status !== "offline";
  return (
    <BottomSheet onClose={onClose}>
      <SheetHead title="Where this runs" sub="This chat is a process on a machine. Point it at whichever machine should run it — same chat, new home." />

      {!sourceReachable ? (
        <div style={{ margin: "0 18px 10px", padding: "var(--space-s) var(--space-m)", background: "var(--m-surface-variant)", border: "var(--border-width) solid var(--m-error)", borderRadius: "var(--radius-s)", font: "var(--weight-medium) var(--text-xs)/1.4 var(--font-sans)", color: "var(--m-on-surface)" }}>
          <b style={{ fontFamily: "var(--font-mono)", color: cur.color }}>{cur.name}</b> is offline — reconnect to it before moving this chat.
        </div>
      ) : null}

      {/* machine list */}
      <div style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)", color: "var(--m-on-surface-variant)", textTransform: "uppercase", letterSpacing: "var(--tracking-wide)", padding: "2px 18px 6px" }}>machine</div>
      {Object.values(MACHINES).map(m => {
        const current = m.name === chat.machine;
        const off = m.status === "offline";
        const disabled = off || (!current && !sourceReachable);
        const keeps = m.models.includes(chat.model);
        const hint = current ? "current home" : off ? "unreachable" : keeps ? "keeps " + chat.model : chat.model + " → " + m.models[0];
        return (
          <div key={m.name} onClick={disabled || current ? undefined : () => onMove(m.name)} style={{ display: "flex", alignItems: "center", gap: 12, padding: "12px 18px", borderTop: "var(--border-width) solid var(--m-outline)", cursor: disabled || current ? "default" : "pointer", opacity: disabled ? 0.5 : 1, background: current ? "var(--m-surface-variant)" : "transparent" }}>
            <StatusDot status={m.status} size={11} />
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ display: "flex", alignItems: "center", gap: 8, whiteSpace: "nowrap" }}>
                <span style={{ font: "var(--weight-bold) var(--text-m)/1 var(--font-mono)", color: m.color }}>{m.name}</span>
                <span style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)", color: "var(--m-on-surface-variant)" }}>{m.role}</span>
              </div>
              <div style={{ font: "var(--weight-medium) var(--text-xs)/1.3 var(--font-mono)", color: off ? "var(--m-error)" : "var(--m-on-surface-variant)", marginTop: 3 }}>{hint}</div>
            </div>
            {current ? <Icon name="check" size={16} color="var(--m-primary)" /> : (!disabled ? <span style={{ font: "var(--weight-semibold) var(--text-xs)/1 var(--font-sans)", color: "var(--m-secondary)" }}>move</span> : null)}
          </div>
        );
      })}

      {/* model on current machine */}
      <div style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)", color: "var(--m-on-surface-variant)", textTransform: "uppercase", letterSpacing: "var(--tracking-wide)", padding: "16px 18px 8px", borderTop: "var(--border-width) solid var(--m-outline)" }}>model on {cur.name}</div>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 7, padding: "0 18px 8px" }}>
        {cur.models.map(mod => {
          const on = mod === chat.model;
          return <button key={mod} onClick={() => onModel(mod)} style={{ display: "inline-flex", alignItems: "center", gap: 6, height: 30, padding: "0 12px", borderRadius: "var(--radius-input)", cursor: "pointer", background: on ? "var(--m-primary)" : "var(--m-surface-variant)", border: "var(--border-width) solid " + (on ? "transparent" : "var(--m-outline)"), color: on ? "var(--m-on-primary)" : "var(--m-on-surface)", font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)" }}>{on ? <Icon name="check" size={12} /> : null}{mod}</button>;
        })}
      </div>

      {/* memory toggle (applies on move) */}
      <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "12px 18px 4px", borderTop: "var(--border-width) solid var(--m-outline)", marginTop: 8 }}>
        <button onClick={() => setMem(v => !v)} style={{ display: "inline-flex", alignItems: "center", gap: 9, background: "none", border: "none", cursor: "pointer", padding: 0 }}>
          <span style={{ width: 20, height: 20, borderRadius: 4, border: "var(--border-width) solid var(--m-outline)", background: mem ? "var(--m-primary)" : "transparent", display: "inline-flex", alignItems: "center", justifyContent: "center" }}>{mem ? <Icon name="check" size={14} color="var(--m-on-primary)" /> : null}</span>
          <span style={{ font: "var(--weight-medium) var(--text-s)/1.3 var(--font-sans)", color: "var(--m-on-surface)", whiteSpace: "nowrap" }}>Bring memory when moving</span>
        </button>
        <span style={{ flex: 1 }} />
        <span style={{ font: "var(--weight-medium) var(--text-xs)/1.3 var(--font-sans)", color: "var(--m-on-surface-variant)" }}>{mem ? "copies sediment" : "stays on " + cur.name}</span>
      </div>
    </BottomSheet>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
