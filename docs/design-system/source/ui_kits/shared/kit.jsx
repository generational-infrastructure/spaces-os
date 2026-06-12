// Shared Spaces OS kit components for the UI-kit prototypes (panel + PWA).
// These mirror the design-system primitives 1:1 visually but are
// self-contained so the click-through kits render without the compiled
// bundle. All driven by the token CSS variables from styles.css.
// Exposed on window.SOS for the per-kit Babel scripts.
const { useState, useEffect, useRef } = React;

/* ---------- Icon (runtime-inlined Tabler SVG, recolours via color) ---------- */
const _iconCache = {};
function Icon({ name, size = 20, color, style = {}, strokeWidth }) {
  const [svg, setSvg] = useState(_iconCache[name] || "");
  useEffect(() => {
    let live = true;
    if (_iconCache[name]) { setSvg(_iconCache[name]); return; }
    fetch(`../../assets/icons/${name}.svg`)
      .then(r => r.text())
      .then(t => {
        if (strokeWidth) t = t.replace(/stroke-width="2"/, `stroke-width="${strokeWidth}"`);
        _iconCache[name] = t;
        if (live) setSvg(t);
      })
      .catch(() => {});
    return () => { live = false; };
  }, [name]);
  return (
    <span
      aria-hidden="true"
      style={{ display: "inline-flex", width: size, height: size, color: color || "currentColor", flexShrink: 0, ...style }}
      ref={el => { if (el && svg) { const s = el.querySelector("svg"); if (!s || s.dataset.n !== name) { el.innerHTML = svg; const ns = el.querySelector("svg"); if (ns) { ns.setAttribute("width", size); ns.setAttribute("height", size); ns.style.display = "block"; ns.dataset.n = name; } } } }}
    />
  );
}

/* ---------- StatusDot ---------- */
const DOT = {
  online: { c: "var(--m-tertiary)", pulse: false },
  offline: { c: "var(--m-error)", pulse: false },
  working: { c: "var(--m-primary)", pulse: true },
  idle: { c: "var(--m-on-surface-variant)", pulse: false },
};
function StatusDot({ status = "online", size = 8, style = {} }) {
  const s = DOT[status] || DOT.idle;
  return <span style={{ display: "inline-block", width: size, height: size, borderRadius: "50%", background: s.c, flexShrink: 0, animation: s.pulse ? "sos-pulse 1.4s var(--ease-standard) infinite" : "none", ...style }} />;
}

/* ---------- MachineChip ---------- */
function MachineChip({ name, color = "var(--m-primary)", status, relayed, size = "md", variant = "outline", style = {}, onClick }) {
  const dim = size === "sm" ? { h: 20, f: "var(--text-xs)", dot: 6 } : { h: 26, f: "var(--text-s)", dot: 8 };
  const solid = variant === "solid";
  const bg = solid ? color : variant === "ghost" ? "transparent" : "var(--m-surface-variant)";
  const label = solid ? "var(--m-on-primary)" : color;
  const border = variant === "outline" ? "var(--border-width) solid var(--m-outline)" : "var(--border-width) solid transparent";
  return (
    <span onClick={onClick} style={{ display: "inline-flex", alignItems: "center", gap: "var(--space-xs)", height: dim.h, padding: "0 var(--space-s)", background: bg, border, borderRadius: "var(--radius-input)", font: `var(--weight-medium) ${dim.f}/1 var(--font-mono)`, color: label, whiteSpace: "nowrap", cursor: onClick ? "pointer" : "default", ...style }}>
      {status ? <StatusDot status={status} size={dim.dot} /> : null}
      <span>{name}</span>
      {relayed ? <Icon name="rotate" size={dim.dot + 4} style={{ opacity: 0.7 }} /> : null}
    </span>
  );
}

/* ---------- Button ---------- */
const BTN = {
  primary: { background: "var(--m-primary)", color: "var(--m-on-primary)" },
  neutral: { background: "var(--m-surface-variant)", color: "var(--m-on-surface)" },
  danger: { background: "var(--m-error)", color: "var(--m-on-error)" },
};
function Button({ children, icon, variant = "primary", disabled, onClick, style = {} }) {
  const v = BTN[variant] || BTN.primary;
  const [h, setH] = useState(false);
  return (
    <button type="button" disabled={disabled} onClick={onClick} onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{ display: "inline-flex", alignItems: "center", justifyContent: "center", gap: "var(--space-xs)", height: 28, padding: "0 var(--space-l)", font: `var(--weight-medium) var(--text-m)/1 var(--font-sans)`, color: v.color, background: v.background, border: "var(--border-width) solid var(--m-outline)", borderRadius: "var(--radius-input)", cursor: disabled ? "default" : "pointer", opacity: disabled ? 0.6 : 1, filter: h && !disabled ? "brightness(1.1)" : "none", transition: "filter var(--duration-fast) var(--ease-standard)", whiteSpace: "nowrap", ...style }}>
      {icon ? <Icon name={icon} size={15} /> : null}{children}
    </button>
  );
}

/* ---------- IconButton ---------- */
function IconButton({ icon, size = 33, active, disabled, title, onClick, style = {} }) {
  const [h, setH] = useState(false);
  const radius = Math.min(6, size / 2);
  const hovering = h && !disabled;
  let bg, fg, border;
  if (active) { bg = "var(--m-error)"; fg = "var(--m-on-error)"; border = "var(--m-error)"; }
  else if (hovering) { bg = "var(--m-hover)"; fg = "var(--m-on-hover)"; border = "var(--m-outline)"; }
  else { bg = "var(--m-surface-variant)"; fg = "var(--m-primary)"; border = "var(--m-outline)"; }
  return (
    <button type="button" title={title} disabled={disabled} onClick={onClick} onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{ display: "inline-flex", alignItems: "center", justifyContent: "center", width: size, height: size, padding: 0, background: bg, color: fg, border: `var(--border-width) solid ${border}`, borderRadius: radius, cursor: disabled ? "default" : "pointer", opacity: disabled ? 0.6 : 1, transition: "background var(--duration-fast) var(--ease-standard), color var(--duration-fast) var(--ease-standard)", ...style }}>
      <Icon name={icon} size={Math.max(14, Math.round(size * 0.45))} />
    </button>
  );
}

/* ---------- Bubble ---------- */
const ACK = { pending: "🕓", sent: "✓", read: "✓✓", warn: "⚠" };
function Bubble({ from = "peer", text = "", time, ack, tps, quote, variant = "text", streaming, style = {} }) {
  const mine = from === "me";
  if (variant === "notification")
    return <div style={{ display: "flex", justifyContent: "center", ...style }}><div style={{ maxWidth: "85%", textAlign: "center", color: "var(--overlay-on-surface-45)", font: "var(--weight-medium) var(--text-s)/1.4 var(--font-sans)" }}>{text}</div></div>;
  if (variant === "thinking")
    return <div style={{ display: "flex", ...style }}><div style={{ maxWidth: "85%", fontStyle: "italic", font: "italic var(--weight-medium) var(--text-s)/1.5 var(--font-sans)", color: "var(--overlay-on-surface-45)" }}>{text || "thinking…"}</div></div>;
  return (
    <div style={{ display: "flex", justifyContent: mine ? "flex-end" : "flex-start", ...style }}>
      <div style={{ maxWidth: "85%", background: mine ? "var(--m-primary)" : "var(--m-surface-variant)", color: mine ? "var(--m-on-primary)" : "var(--m-on-surface)", border: mine ? "none" : "var(--border-width) solid var(--m-outline)", borderRadius: "var(--radius-s)", padding: "var(--space-m)", display: "flex", flexDirection: "column", gap: "var(--space-xxs)" }}>
        {quote ? <div style={{ background: mine ? "var(--overlay-on-primary-15)" : "var(--overlay-on-surface-08)", color: mine ? "var(--overlay-on-primary-60)" : "var(--m-on-surface-variant)", borderRadius: "var(--radius-xs)", padding: "var(--space-xs) var(--space-s)", font: "var(--weight-medium) var(--text-xs)/1.4 var(--font-sans)", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>↳ {quote}</div> : null}
        <div style={{ font: "var(--weight-medium) var(--text-m)/1.5 var(--font-sans)", whiteSpace: "pre-wrap", wordBreak: "break-word" }}>{text}{streaming ? <span style={{ marginLeft: 2, opacity: 0.7 }}>▍</span> : null}</div>
        <div style={{ display: "flex", alignItems: "center", gap: "var(--space-xs)", justifyContent: mine ? "flex-end" : "flex-start" }}>
          {time ? <span style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)", color: mine ? "var(--overlay-on-primary-60)" : "var(--m-on-surface-variant)" }}>{time}</span> : null}
          {!mine && tps ? <span style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)", color: "var(--m-on-surface-variant)" }}>{tps.toFixed(1)} t/s</span> : null}
          {mine && ack ? <span style={{ font: "var(--text-s)/1 var(--font-sans)", color: ack === "warn" ? "var(--m-error)" : "var(--overlay-on-primary-80)" }}>{ACK[ack]}</span> : null}
        </div>
      </div>
    </div>
  );
}

/* ---------- ConfirmCard ---------- */
function ConfirmCard({ title = "Run shell command?", command = "", state = "pending", machine, answeredBy, onAllow, onDeny, style = {} }) {
  const bc = state === "allowed" ? "var(--m-tertiary)" : state === "denied" ? "var(--m-error)" : "var(--m-primary)";
  return (
    <div style={{ background: "var(--m-surface-variant)", border: `var(--border-width) solid ${bc}`, borderRadius: "var(--radius-s)", padding: "var(--space-m)", display: "flex", flexDirection: "column", gap: "var(--space-s)", ...style }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: "var(--space-s)" }}>
        <span style={{ font: "var(--weight-bold) var(--text-m)/1.2 var(--font-sans)", color: "var(--m-on-surface)" }}>{title}</span>
        {machine ? <MachineChip name={machine.name} color={machine.color} size="sm" /> : null}
      </div>
      <pre style={{ margin: 0, background: "var(--m-surface)", border: "var(--border-width) solid var(--m-outline)", borderRadius: "var(--radius-xs)", padding: "var(--space-s) var(--space-m)", font: "var(--weight-medium) var(--text-s)/1.5 var(--font-mono)", color: "var(--m-on-surface)", whiteSpace: "pre-wrap", wordBreak: "break-all" }}>{command}</pre>
      {state === "pending" ? (
        <div style={{ display: "flex", justifyContent: "flex-end", gap: "var(--space-s)" }}>
          <Button variant="neutral" onClick={onDeny}>Deny</Button>
          <Button variant="primary" onClick={onAllow}>Allow</Button>
        </div>
      ) : (
        <div style={{ display: "flex", justifyContent: "flex-end", alignItems: "center", gap: "var(--space-s)" }}>
          {answeredBy ? <span style={{ font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)", color: "var(--m-on-surface-variant)" }}>{answeredBy}</span> : null}
          <span style={{ font: "var(--weight-bold) var(--text-s)/1 var(--font-sans)", color: state === "allowed" ? "var(--m-tertiary)" : "var(--m-error)" }}>{state === "allowed" ? "✓ allowed" : "✗ denied"}</span>
        </div>
      )}
    </div>
  );
}

/* ---------- TextInput ---------- */
function TextInput({ multiline, tone = "default", value, onChange, placeholder, rows = 1, style = {} }) {
  const [focus, setFocus] = useState(false);
  const compose = tone === "compose";
  const focusColor = compose ? "var(--m-secondary)" : "var(--m-primary)";
  const bg = compose ? "var(--m-surface)" : "var(--m-surface-variant)";
  const shared = { width: "100%", boxSizing: "border-box", resize: "none", background: "transparent", border: "none", outline: "none", color: "var(--m-on-surface)", font: "var(--weight-medium) var(--text-m)/1.4 var(--font-sans)", padding: "var(--space-s) var(--space-m)" };
  return (
    <div style={{ background: bg, border: `var(--border-width) solid ${focus ? focusColor : "var(--m-outline)"}`, borderRadius: "var(--radius-input)", transition: "border-color var(--duration-fast) var(--ease-standard)", display: "flex", ...style }}>
      {multiline
        ? <textarea rows={rows} value={value} onChange={onChange} placeholder={placeholder} onFocus={() => setFocus(true)} onBlur={() => setFocus(false)} style={shared} />
        : <input type="text" value={value} onChange={onChange} placeholder={placeholder} onFocus={() => setFocus(true)} onBlur={() => setFocus(false)} style={shared} />}
    </div>
  );
}

/* ---------- Divider ---------- */
function Divider({ vertical, style = {} }) {
  return <div style={{ background: "var(--m-outline)", flexShrink: 0, ...(vertical ? { width: "var(--border-width)", alignSelf: "stretch" } : { height: "var(--border-width)", width: "100%" }), ...style }} />;
}

/* ---------- shared machine catalogue (used by both kits) ---------- */
const MACHINES = {
  kiwi:   { name: "kiwi",   color: "var(--m-primary)",   role: "desktop",   status: "online",  relayed: false,
            models: ["gemma3:27b", "qwen2.5-coder:14b", "llama3.2:3b"] },
  studio: { name: "studio", color: "var(--m-secondary)", role: "workstation",    status: "offline", relayed: false,
            models: ["llama3.3:70b", "deepseek-r1:32b", "qwen2.5-coder:32b"] },
  nas:    { name: "nas",    color: "var(--m-tertiary)",  role: "home server", status: "online", relayed: true,
            models: ["qwen2.5:7b", "phi4:14b"] },
};

window.SOS = { Icon, StatusDot, MachineChip, Button, IconButton, TextInput, Divider, Bubble, ConfirmCard, MACHINES };

// keyframes once
if (!document.getElementById("sos-kf")) {
  const st = document.createElement("style");
  st.id = "sos-kf";
  st.textContent = "@keyframes sos-pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.45;transform:scale(.8)}}";
  document.head.appendChild(st);
}
