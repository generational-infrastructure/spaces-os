// pi-chat Quickshell sidepanel — calmer, machine-aware redesign.
// Key changes from the noctalia first-draft:
//   · no always-on horizontal tab strip (doesn't scale) — chats live in a
//     scrollable drawer opened from a single title switcher
//   · the chat name appears ONCE (the header title), not in a tab too
//   · the 5 header icons collapse into one overflow menu
//   · sharper corners throughout
const { useState, useEffect, useRef } = React;
const { Icon, StatusDot, MachineChip, Button, IconButton, Bubble, ConfirmCard, MACHINES } = window.SOS;

const PANEL_W = 480;
let _id = 100; const uid = () => "m" + (++_id);

function seedSessions() {
  return [
    { id: "s1", name: "Fix deploy.sh", machine: "kiwi", model: "qwen2.5-coder:14b", lifecycle: "idle", needsYou: true, unread: 0, time: "3m",
      preview: "Run shell command? sed -i …", messages: [
        { id: uid(), from: "me", text: "scan deploy.sh for footguns", time: "4m", ack: "read" },
        { id: uid(), from: "peer", type: "thinking", text: "Checking error handling and the migration / health-check ordering…" },
        { id: uid(), from: "peer", text: "Two issues:\n1. no `set -euo pipefail`\n2. the migration runs *before* the health check.\n\nPatch both?", time: "3m", tps: 47.9 },
        { id: uid(), from: "me", text: "yes, patch both", time: "2m", ack: "read", quote: "Patch both?" },
        { id: "confirm1", type: "confirm", command: "sed -i '1i set -euo pipefail' deploy.sh", confirmState: "pending" },
      ] },
    { id: "s2", name: "Groceries", machine: "kiwi", model: "llama3.2:3b", lifecycle: "working", needsYou: false, unread: 2, time: "10m",
      preview: "Sheet-pan harissa chicken?", messages: [
        { id: uid(), from: "me", text: "add oat milk + a tuesday dinner idea", time: "12m", ack: "read" },
        { id: uid(), from: "peer", text: "Added oat milk. For Tuesday: sheet-pan harissa chicken?", time: "10m", tps: 61.0 },
      ] },
    { id: "s3", name: "Summarize refs", machine: "studio", model: "llama3.3:70b", lifecycle: "idle", needsYou: false, unread: 0, time: "1h",
      preview: "Pushed a synthesis to notes/…", messages: [
        { id: uid(), from: "me", text: "summarize the three papers in ~/refs", time: "1h", ack: "sent" },
        { id: uid(), from: "peer", text: "Pushed a synthesis to notes/synthesis.md.", time: "1h", tps: 18.4 },
      ] },
    { id: "s4", name: "Berlin trip", machine: "nas", model: "qwen2.5:7b", lifecycle: "idle", needsYou: false, unread: 0, time: "2h",
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

/* ============================ desktop scene ============================ */
function App() {
  const [sessions, setSessions] = useState(seedSessions);
  const [activeId, setActiveId] = useState("s1");
  const active = sessions.find(s => s.id === activeId);
  function patch(id, fn) { setSessions(ss => ss.map(s => s.id === id ? fn(s) : s)); }

  return (
    <div style={{ position: "relative", width: "100vw", height: "100vh", overflow: "hidden" }}>
      <TopBar />
      <DesktopHint />
      <div style={{ position: "absolute", top: 36, right: 0, bottom: 0, width: PANEL_W,
        background: "var(--m-surface)", borderLeft: "var(--border-width) solid var(--m-outline)",
        borderTopLeftRadius: "var(--radius-s)", boxShadow: "var(--shadow-overlay)", display: "flex" }}>
        <Panel sessions={sessions} setSessions={setSessions} activeId={activeId} setActiveId={setActiveId} active={active} patch={patch} />
      </div>
    </div>
  );
}

function TopBar() {
  const [clock, setClock] = useState("");
  useEffect(() => { const t = () => setClock(new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })); t(); const i = setInterval(t, 10000); return () => clearInterval(i); }, []);
  return (
    <div style={{ position: "absolute", top: 0, left: 0, right: 0, height: 36, display: "flex", alignItems: "center", padding: "0 14px", gap: 12, background: "rgba(7,7,34,0.72)", backdropFilter: "blur(8px)", borderBottom: "var(--border-width) solid var(--m-outline)", zIndex: 5 }}>
      <div style={{ display: "flex", gap: 6 }}>{[1, 2, 3].map(n => <span key={n} style={{ width: 7, height: 7, borderRadius: 2, background: n === 1 ? "var(--m-primary)" : "var(--m-outline)" }} />)}</div>
      <div style={{ flex: 1 }} />
      <span style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)", color: "var(--m-on-surface-variant)", marginRight: 2 }}>machines</span>
      {Object.values(MACHINES).map(m => <MachineChip key={m.name} name={m.name} color={m.color} status={m.status} relayed={m.relayed} size="sm" />)}
      <span style={{ width: 1, height: 16, background: "var(--m-outline)", margin: "0 4px" }} />
      <span style={{ font: "var(--weight-medium) var(--text-s)/1 var(--font-mono)", color: "var(--m-on-surface)" }}>{clock}</span>
    </div>
  );
}

function DesktopHint() {
  return (
    <div style={{ position: "absolute", left: 40, bottom: 34, color: "var(--m-on-surface-variant)", maxWidth: 360 }}>
      <div style={{ font: "var(--weight-semibold) var(--text-l)/1.3 var(--font-sans)", color: "var(--m-on-surface)", opacity: 0.5 }}>Spaces OS</div>
      <div style={{ font: "var(--weight-medium) var(--text-s)/1.5 var(--font-sans)", opacity: 0.45, marginTop: 4 }}>
        <span style={{ fontFamily: "var(--font-mono)", color: "var(--m-primary)" }}>Mod&nbsp;+&nbsp;A</span> agent panel · <span style={{ fontFamily: "var(--font-mono)", color: "var(--m-primary)" }}>Mod&nbsp;+&nbsp;/</span> background task
      </div>
    </div>
  );
}

/* ============================ the panel ============================ */
function Panel({ sessions, setSessions, activeId, setActiveId, active, patch }) {
  const [draft, setDraft] = useState("");
  const [drawer, setDrawer] = useState(false);   // chat list
  const [runOn, setRunOn] = useState(false);     // new-chat picker
  const [whereFor, setWhereFor] = useState(null);  // "where this runs" (machine + model)
  const [overflow, setOverflow] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const listRef = useRef(null);
  const machine = MACHINES[active.machine];
  const reachable = machine.status !== "offline";

  useEffect(() => { if (listRef.current) listRef.current.scrollTop = listRef.current.scrollHeight; }, [active.messages.length, activeId]);

  function send() {
    if (!draft.trim() || !reachable) return;
    const text = draft.trim();
    patch(active.id, s => ({ ...s, messages: [...s.messages, { id: uid(), from: "me", text, time: "now", ack: "sent" }] }));
    setDraft("");
    setTimeout(() => patch(active.id, s => ({ ...s, messages: [...s.messages, { id: uid(), from: "peer", text: "On it — running on " + s.machine + ".", time: "now", tps: 44.0 }] })), 1000);
  }
  function answerConfirm(id, ok) { patch(active.id, s => ({ ...s, needsYou: false, messages: s.messages.map(m => m.id === id ? { ...m, confirmState: ok ? "allowed" : "denied" } : m) })); }
  function startChat(mk) {
    const m = MACHINES[mk]; const id = "s" + Date.now();
    setSessions(ss => [...ss, { id, name: "New chat", machine: mk, model: m.models[0], lifecycle: "idle", needsYou: false, unread: 0, time: "now", preview: "—", messages: [{ id: uid(), type: "notification", text: m.name + " · new session · " + m.models[0] }] }]);
    setActiveId(id); setRunOn(false); setDrawer(false);
  }
  function doMove(tk) {
    const sess = whereFor, t = MACHINES[tk], nm = t.models.includes(sess.model) ? sess.model : t.models[0];
    patch(sess.id, s => ({ ...s, machine: tk, model: nm, messages: [...s.messages, { id: uid(), type: "notification", text: "now running on " + t.name + " · " + nm }] }));
    setWhereFor(w => w && ({ ...w, machine: tk, model: nm }));
  }
  function setModel(model) { patch(whereFor.id, s => ({ ...s, model })); setWhereFor(w => w && ({ ...w, model })); }

  return (
    <div style={{ display: "flex", flexDirection: "column", width: "100%", padding: "var(--space-l)", gap: "var(--space-s)", position: "relative" }}>
      {/* calm header: one title + switcher, machine context, 2 actions */}
      <div style={{ position: "relative", display: "flex", alignItems: "center", gap: "var(--space-xs)" }}>
        <button onClick={() => setDrawer(true)} title="All chats"
          style={{ flex: 1, minWidth: 0, display: "flex", alignItems: "center", gap: 7, background: "none", border: "none", cursor: "pointer", padding: "4px 2px", textAlign: "left" }}>
          <Icon name="message-chatbot" size={20} color="var(--m-primary)" />
          <span style={{ font: "var(--weight-bold) var(--text-l)/1.15 var(--font-sans)", color: "var(--m-on-surface)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{active.name}</span>
          <Icon name="chevron-down" size={15} color="var(--m-on-surface-variant)" />
        </button>
        <IconButton icon="plus" size={30} title="New chat" onClick={() => setRunOn(true)} />
        <IconButton icon="dots-vertical" size={30} title="Options" onClick={() => setOverflow(v => !v)} />
        {overflow ? <OverflowMenu onClose={() => setOverflow(false)} onSearch={() => { setSearchOpen(true); setOverflow(false); }} /> : null}
      </div>

      {/* runtime control — where this chat runs (machine + model); tap to move / switch */}
      <button onClick={() => setWhereFor(active)} style={{ display: "flex", alignItems: "center", gap: "var(--space-xs)", padding: "7px 10px", background: "var(--m-surface-variant)", border: "var(--border-width) solid var(--m-outline)", borderRadius: "var(--radius-input)", cursor: "pointer", width: "100%" }}>
        <StatusDot status={reachable ? "online" : "offline"} size={8} />
        <span style={{ font: "var(--weight-bold) var(--text-s)/1 var(--font-mono)", color: machine.color, flexShrink: 0 }}>{machine.name}</span>
        <span style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)", color: "var(--m-on-surface-variant)", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>· {active.model}</span>
        <span style={{ flex: 1 }} />
        <span style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)", color: "var(--m-secondary)", whiteSpace: "nowrap", flexShrink: 0 }}>Where it runs</span>
        <Icon name="chevron-down" size={14} color="var(--m-secondary)" />
      </button>

      {searchOpen ? <SearchBar onClose={() => setSearchOpen(false)} /> : null}

      <div style={{ height: "var(--border-width)", background: "var(--m-outline)" }} />

      {/* messages */}
      <div ref={listRef} style={{ flex: 1, minHeight: 0, overflowY: "auto", display: "flex", flexDirection: "column", gap: "var(--space-m)", paddingRight: 2 }}>
        {active.messages.map(m => m.type === "confirm"
          ? <ConfirmCard key={m.id} command={m.command} state={m.confirmState} machine={{ name: machine.name, color: machine.color }} onAllow={() => answerConfirm(m.id, true)} onDeny={() => answerConfirm(m.id, false)} />
          : <Bubble key={m.id} from={m.from} text={m.text} time={m.time} ack={m.ack} tps={m.tps} quote={m.quote} variant={m.type === "thinking" ? "thinking" : m.type === "notification" ? "notification" : "text"} />)}
      </div>

      {!reachable ? (
        <div style={{ display: "flex", alignItems: "center", gap: "var(--space-s)", padding: "var(--space-s) var(--space-m)", background: "var(--m-surface-variant)", border: "var(--border-width) solid var(--m-error)", borderRadius: "var(--radius-s)" }}>
          <Icon name="database-off" size={16} color="var(--m-error)" />
          <span style={{ flex: 1, font: "var(--weight-medium) var(--text-s)/1.4 var(--font-sans)", color: "var(--m-on-surface)" }}>Can’t reach <b style={{ fontFamily: "var(--font-mono)", color: machine.color }}>{machine.name}</b> — cached, read-only.</span>
        </div>
      ) : null}

      <Compose draft={draft} setDraft={setDraft} send={send} reachable={reachable} machine={machine} />

      {/* overlays */}
      {drawer ? <ChatDrawer sessions={sessions} activeId={activeId} onClose={() => setDrawer(false)} onPick={id => { setActiveId(id); setDrawer(false); }} onNew={() => { setDrawer(false); setRunOn(true); }} /> : null}
      {runOn ? <RunOnSheet onClose={() => setRunOn(false)} onPick={startChat} /> : null}
      {whereFor ? <WhereSheet sess={whereFor} onClose={() => setWhereFor(null)} onMove={doMove} onModel={setModel} /> : null}
    </div>
  );
}

function OverflowMenu({ onClose, onSearch }) {
  const rows = [
    { icon: "search", label: "Search messages", onClick: onSearch },
    { icon: "brain", label: "Long-term memory: on", onClick: onClose },
    { icon: "rotate", label: "Restart conversation", onClick: onClose },
    { icon: "eye", label: "Hide thinking", onClick: onClose },
    { icon: "eraser", label: "Wipe memory", onClick: onClose, danger: true },
  ];
  return (
    <>
      <div onClick={onClose} style={{ position: "fixed", inset: 0, zIndex: 24 }} />
      <div style={{ position: "absolute", top: 38, right: 0, zIndex: 25, minWidth: 210, background: "var(--m-surface-variant)", border: "var(--border-width) solid var(--m-outline)", borderRadius: "var(--radius-input)", boxShadow: "var(--shadow-popup)", padding: "var(--space-xs)" }}>
        {rows.map(r => (
          <div key={r.label} className="sos-menu-row" onClick={r.onClick}
            style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 9px", borderRadius: "var(--radius-s)", cursor: "pointer", font: "var(--weight-medium) var(--text-s)/1 var(--font-sans)", color: r.danger ? "var(--m-error)" : "var(--m-on-surface)" }}>
            <Icon name={r.icon} size={16} color={r.danger ? "var(--m-error)" : "var(--m-on-surface-variant)"} />{r.label}
          </div>
        ))}
      </div>
    </>
  );
}

function SearchBar({ onClose }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: "var(--space-s)" }}>
      <div style={{ flex: 1, display: "flex", background: "var(--m-surface-variant)", border: "var(--border-width) solid var(--m-secondary)", borderRadius: "var(--radius-input)", padding: "var(--space-s) var(--space-m)" }}>
        <input autoFocus placeholder="Search messages…" style={{ width: "100%", background: "transparent", border: "none", outline: "none", color: "var(--m-on-surface)", font: "var(--weight-medium) var(--text-m)/1 var(--font-sans)" }} />
      </div>
      <IconButton icon="x" size={28} title="Close search" onClick={onClose} />
    </div>
  );
}

function Compose({ draft, setDraft, send, reachable, machine }) {
  return (
    <div style={{ display: "flex", alignItems: "flex-end", gap: "var(--space-s)" }}>
      <div style={{ flex: 1, display: "flex", background: "var(--m-surface)", border: "var(--border-width) solid var(--m-outline)", borderRadius: "var(--radius-input)", opacity: reachable ? 1 : 0.5 }}>
        <textarea value={draft} disabled={!reachable} onChange={e => setDraft(e.target.value)}
          onKeyDown={e => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); } }}
          placeholder={reachable ? "Message " + machine.name + "…" : "Unreachable — read-only"} rows={1}
          style={{ width: "100%", resize: "none", background: "transparent", border: "none", outline: "none", color: "var(--m-on-surface)", font: "var(--weight-medium) var(--text-m)/1.4 var(--font-sans)", padding: "var(--space-s) var(--space-m)", maxHeight: 120 }} />
      </div>
      <IconButton icon="microphone" size={36} title="Voice to text" disabled={!reachable} />
      <IconButton icon="paperclip" size={36} title="Attach image" disabled={!reachable} />
      <IconButton icon="send" size={36} title="Send" disabled={!reachable || !draft.trim()} onClick={send} />
    </div>
  );
}

/* ============================ chat drawer (scales) ============================ */
function ChatDrawer({ sessions, activeId, onClose, onPick, onNew }) {
  const [filter, setFilter] = useState("all");
  const machines = Object.values(MACHINES);
  const shown = sessions.filter(s => filter === "all" || s.machine === filter);
  return (
    <div onClick={onClose} style={{ position: "absolute", inset: 0, background: "rgba(5,5,19,0.6)", backdropFilter: "blur(2px)", borderRadius: "var(--radius-s) 0 0 0", zIndex: 30 }}>
      <div onClick={e => e.stopPropagation()} style={{ position: "absolute", top: 0, left: 0, right: 0, maxHeight: "82%", display: "flex", flexDirection: "column", background: "var(--m-surface)", borderBottom: "var(--border-width) solid var(--m-outline)", borderRadius: "var(--radius-s) 0 var(--radius-s) var(--radius-s)", boxShadow: "var(--shadow-popup)" }}>
        <div style={{ display: "flex", alignItems: "center", gap: "var(--space-s)", padding: "var(--space-m) var(--space-l)" }}>
          <span style={{ flex: 1, font: "var(--weight-bold) var(--text-l)/1 var(--font-sans)", color: "var(--m-on-surface)" }}>Chats</span>
          <Button icon="plus" onClick={onNew}>New</Button>
          <IconButton icon="x" size={28} title="Close" onClick={onClose} />
        </div>
        <div style={{ display: "flex", gap: "var(--space-xs)", padding: "0 var(--space-l) var(--space-s)", overflowX: "auto" }}>
          <DrawerFilter label="All" active={filter === "all"} onClick={() => setFilter("all")} />
          {machines.map(m => (
            <button key={m.name} onClick={() => setFilter(m.name)} style={{ display: "inline-flex", alignItems: "center", gap: 6, height: 26, padding: "0 10px", flexShrink: 0, borderRadius: "var(--radius-input)", cursor: "pointer", whiteSpace: "nowrap",
              background: filter === m.name ? m.color : "var(--m-surface-variant)", border: "var(--border-width) solid " + (filter === m.name ? "transparent" : "var(--m-outline)"), color: filter === m.name ? "var(--m-on-primary)" : m.color, font: "var(--weight-medium) var(--text-s)/1 var(--font-mono)" }}>
              <StatusDot status={m.status} size={6} />{m.name}
            </button>
          ))}
        </div>
        <div style={{ overflowY: "auto", padding: "0 var(--space-s) var(--space-s)", display: "flex", flexDirection: "column", gap: "var(--space-xs)" }}>
          {shown.map(s => <ChatRow key={s.id} s={s} active={s.id === activeId} onClick={() => onPick(s.id)} />)}
        </div>
      </div>
    </div>
  );
}

function DrawerFilter({ label, active, onClick }) {
  return <button onClick={onClick} style={{ height: 26, padding: "0 12px", flexShrink: 0, borderRadius: "var(--radius-input)", cursor: "pointer", background: active ? "var(--m-on-surface)" : "var(--m-surface-variant)", border: "var(--border-width) solid " + (active ? "transparent" : "var(--m-outline)"), color: active ? "var(--m-surface)" : "var(--m-on-surface)", font: "var(--weight-semibold) var(--text-s)/1 var(--font-sans)" }}>{label}</button>;
}

function ChatRow({ s, active, onClick }) {
  const m = MACHINES[s.machine];
  const state = chatState(s);
  const unreachable = state === "unreachable";
  return (
    <button onClick={onClick} style={{ width: "100%", textAlign: "left", display: "flex", gap: "var(--space-s)", alignItems: "stretch", padding: "var(--space-s) var(--space-m)", background: active ? "var(--m-surface-variant)" : "transparent", border: "var(--border-width) solid " + (active ? "var(--m-outline)" : "transparent"), borderRadius: "var(--radius-s)", cursor: "pointer", opacity: unreachable ? 0.6 : 1 }}>
      <div style={{ width: 3, alignSelf: "stretch", borderRadius: 2, background: m.color, flexShrink: 0 }} />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <span style={{ flex: 1, font: "var(--weight-bold) var(--text-m)/1.2 var(--font-sans)", color: "var(--m-on-surface)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{s.name}</span>
          <span style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)", color: "var(--m-on-surface-variant)", flexShrink: 0 }}>{s.time}</span>
        </div>
        <div style={{ font: "var(--weight-medium) var(--text-s)/1.35 var(--font-sans)", color: "var(--m-on-surface-variant)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", marginTop: 2 }}>{s.preview}</div>
        <div style={{ display: "flex", alignItems: "center", gap: 8, marginTop: 6 }}>
          <MachineChip name={m.name} color={m.color} status={m.status} relayed={m.relayed} size="sm" />
          <span style={{ flex: 1 }} />
          <ChatBadge state={state} unread={s.unread} />
        </div>
      </div>
    </button>
  );
}

function ChatBadge({ state, unread }) {
  if (state === "needs-you")
    return <span style={{ display: "inline-flex", alignItems: "center", gap: 5, height: 19, padding: "0 8px", borderRadius: "var(--radius-input)", background: "var(--m-primary)", color: "var(--m-on-primary)", font: "var(--weight-bold) var(--text-xs)/1 var(--font-sans)" }}><Icon name="key" size={11} />needs you</span>;
  if (state === "working")
    return <span style={{ display: "inline-flex", alignItems: "center", gap: 5, font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)", color: "var(--m-primary)" }}><StatusDot status="working" size={7} />working</span>;
  if (state === "unreachable")
    return <span style={{ display: "inline-flex", alignItems: "center", gap: 5, font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)", color: "var(--m-on-surface-variant)" }}><Icon name="database-off" size={12} />offline</span>;
  if (unread > 0)
    return <span style={{ minWidth: 18, height: 18, padding: "0 5px", display: "inline-flex", alignItems: "center", justifyContent: "center", borderRadius: "var(--radius-xs)", background: "var(--m-primary)", color: "var(--m-on-primary)", font: "var(--weight-bold) var(--text-xs)/1 var(--font-sans)" }}>{unread}</span>;
  return null;
}

/* ============================ sheets ============================ */
function Scrim({ onClose, children }) {
  return (
    <div onClick={onClose} style={{ position: "absolute", inset: 0, background: "rgba(5,5,19,0.82)", backdropFilter: "blur(3px)", borderRadius: "var(--radius-s) 0 0 0", display: "flex", alignItems: "flex-start", justifyContent: "center", paddingTop: 60, zIndex: 35 }}>
      <div onClick={e => e.stopPropagation()} style={{ width: PANEL_W - 52, background: "var(--m-surface)", border: "var(--border-width) solid var(--m-outline)", borderRadius: "var(--radius-s)", boxShadow: "var(--shadow-popup)", overflow: "hidden" }}>{children}</div>
    </div>
  );
}

function SheetHead({ title, sub, roadmap, onClose }) {
  return (
    <div style={{ display: "flex", alignItems: "flex-start", gap: "var(--space-s)", padding: "var(--space-m)", borderBottom: "var(--border-width) solid var(--m-outline)" }}>
      <div style={{ flex: 1 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <span style={{ font: "var(--weight-bold) var(--text-l)/1.2 var(--font-sans)", color: "var(--m-on-surface)", whiteSpace: "nowrap" }}>{title}</span>
          {roadmap ? <span style={{ font: "var(--weight-bold) var(--text-xs)/1 var(--font-mono)", color: "var(--m-on-tertiary)", background: "var(--m-tertiary)", borderRadius: "var(--radius-xs)", padding: "2px 7px" }}>ROADMAP</span> : null}
        </div>
        {sub ? <div style={{ font: "var(--weight-medium) var(--text-s)/1.4 var(--font-sans)", color: "var(--m-on-surface-variant)", marginTop: 3 }}>{sub}</div> : null}
      </div>
      <IconButton icon="x" size={26} title="Close" onClick={onClose} />
    </div>
  );
}

function MachineRow({ m, disabled, reason, right, onClick }) {
  return (
    <div onClick={disabled ? undefined : onClick} className={disabled ? "" : "sos-menu-row"} style={{ display: "flex", alignItems: "center", gap: "var(--space-s)", padding: "var(--space-m)", cursor: disabled ? "default" : "pointer", opacity: disabled ? 0.5 : 1 }}>
      <StatusDot status={m.status} size={10} />
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, whiteSpace: "nowrap", overflow: "hidden" }}>
          <span style={{ font: "var(--weight-bold) var(--text-m)/1 var(--font-mono)", color: m.color }}>{m.name}</span>
          <span style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)", color: "var(--m-on-surface-variant)" }}>{m.role}</span>
          {m.relayed ? <span style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)", color: "var(--m-on-surface-variant)" }}>· relayed</span> : null}
        </div>
        <div style={{ font: "var(--weight-medium) var(--text-xs)/1.4 var(--font-mono)", color: disabled ? "var(--m-error)" : "var(--m-on-surface-variant)", marginTop: 4, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{reason || m.models.join(" · ")}</div>
      </div>
      {right || (!disabled ? <Icon name="chevron-down" size={16} color="var(--m-on-surface-variant)" style={{ transform: "rotate(-90deg)" }} /> : null)}
    </div>
  );
}

function RunOnSheet({ onClose, onPick }) {
  return (
    <Scrim onClose={onClose}>
      <SheetHead title="Start a chat" sub="Pick the machine that will run the agent. Its models are scoped to that machine." onClose={onClose} />
      {Object.values(MACHINES).map((m, i) => { const off = m.status === "offline";
        return <div key={m.name} style={{ borderTop: i ? "var(--border-width) solid var(--m-outline)" : "none" }}><MachineRow m={m} disabled={off} reason={off ? "unreachable — can’t start a chat here" : undefined} onClick={() => onPick(m.name)} /></div>; })}
    </Scrim>
  );
}

/* "Where this runs" — reframed move: machine + model unified in one sheet. */
function WhereSheet({ sess, onClose, onMove, onModel }) {
  const [mem, setMem] = useState(false);
  const cur = MACHINES[sess.machine];
  const sourceReachable = cur.status !== "offline";
  return (
    <Scrim onClose={onClose}>
      <SheetHead title="Where this runs" sub="This chat is a process on a machine. Point it wherever it should run — same chat, new home." onClose={onClose} />
      {!sourceReachable ? (
        <div style={{ margin: "var(--space-m) var(--space-m) 0", padding: "var(--space-s) var(--space-m)", background: "var(--m-surface-variant)", border: "var(--border-width) solid var(--m-error)", borderRadius: "var(--radius-s)", font: "var(--weight-medium) var(--text-xs)/1.4 var(--font-sans)", color: "var(--m-on-surface)" }}>
          <b style={{ fontFamily: "var(--font-mono)", color: cur.color }}>{cur.name}</b> is offline — reconnect before moving.
        </div>
      ) : null}
      <div style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)", color: "var(--m-on-surface-variant)", textTransform: "uppercase", letterSpacing: "var(--tracking-wide)", padding: "var(--space-m) var(--space-m) var(--space-xs)" }}>machine</div>
      {Object.values(MACHINES).map(m => {
        const current = m.name === sess.machine, off = m.status === "offline";
        const disabled = off || (!current && !sourceReachable);
        const keeps = m.models.includes(sess.model);
        const reason = current ? "current home" : off ? "unreachable" : keeps ? "keeps " + sess.model : sess.model + " → " + m.models[0];
        return <div key={m.name} style={{ borderTop: "var(--border-width) solid var(--m-outline)" }}>
          <MachineRow m={m} disabled={disabled && !current} reason={reason}
            onClick={!disabled && !current ? () => onMove(m.name) : undefined}
            right={current ? <Icon name="check" size={16} color="var(--m-primary)" /> : (!disabled ? <span style={{ font: "var(--weight-semibold) var(--text-xs)/1 var(--font-sans)", color: "var(--m-secondary)" }}>move</span> : null)} />
        </div>;
      })}
      <div style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)", color: "var(--m-on-surface-variant)", textTransform: "uppercase", letterSpacing: "var(--tracking-wide)", padding: "var(--space-m) var(--space-m) var(--space-xs)", borderTop: "var(--border-width) solid var(--m-outline)" }}>model on {cur.name}</div>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 7, padding: "0 var(--space-m) var(--space-s)" }}>
        {cur.models.map(mod => { const on = mod === sess.model;
          return <button key={mod} onClick={() => onModel(mod)} style={{ display: "inline-flex", alignItems: "center", gap: 6, height: 28, padding: "0 11px", borderRadius: "var(--radius-input)", cursor: "pointer", background: on ? "var(--m-primary)" : "var(--m-surface-variant)", border: "var(--border-width) solid " + (on ? "transparent" : "var(--m-outline)"), color: on ? "var(--m-on-primary)" : "var(--m-on-surface)", font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)" }}>{on ? <Icon name="check" size={12} /> : null}{mod}</button>; })}
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: "var(--space-s)", padding: "var(--space-m)", borderTop: "var(--border-width) solid var(--m-outline)", background: "var(--m-surface-variant)" }}>
        <button onClick={() => setMem(v => !v)} style={{ display: "inline-flex", alignItems: "center", gap: 8, background: "none", border: "none", cursor: "pointer", padding: 0 }}>
          <span style={{ width: 18, height: 18, borderRadius: 4, border: "var(--border-width) solid var(--m-outline)", background: mem ? "var(--m-primary)" : "transparent", display: "inline-flex", alignItems: "center", justifyContent: "center" }}>{mem ? <Icon name="check" size={13} color="var(--m-on-primary)" /> : null}</span>
          <span style={{ font: "var(--weight-medium) var(--text-s)/1.3 var(--font-sans)", color: "var(--m-on-surface)", whiteSpace: "nowrap" }}>Bring memory when moving</span>
        </button>
        <span style={{ flex: 1 }} />
        <span style={{ font: "var(--weight-medium) var(--text-xs)/1.3 var(--font-sans)", color: "var(--m-on-surface-variant)", textAlign: "right" }}>{mem ? "copies sediment" : "stays on " + cur.name}</span>
      </div>
    </Scrim>
  );
}

const _st = document.createElement("style");
_st.textContent = ".sos-menu-row:hover{background:var(--m-hover);color:var(--m-on-hover)!important}.sos-menu-row:hover *{color:var(--m-on-hover)!important}";
document.head.appendChild(_st);

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
