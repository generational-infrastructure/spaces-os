// StatusDot — the tiny live-state indicator used throughout both
// clients (the panel's relayDot, session unread marks, machine
// reachability). Colour encodes state; `working` softly pulses.
import React from "react";

const STATUS = {
  online:  { color: "var(--m-tertiary)", pulse: false }, // reachable
  offline: { color: "var(--m-error)",    pulse: false }, // unreachable
  working: { color: "var(--m-primary)",  pulse: true  }, // agent busy
  idle:    { color: "var(--m-on-surface-variant)", pulse: false },
  error:   { color: "var(--m-error)",    pulse: false },
};

export function StatusDot({ status = "online", size = 8, style = {}, ...rest }) {
  const s = STATUS[status] || STATUS.idle;
  return (
    <span
      role="status"
      aria-label={status}
      style={{
        display: "inline-block",
        width: `${size}px`,
        height: `${size}px`,
        borderRadius: "50%",
        background: s.color,
        flexShrink: 0,
        animation: s.pulse ? `sos-pulse 1.4s var(--ease-standard) infinite` : "none",
        ...style,
      }}
      {...rest}
    >
      <style>{`@keyframes sos-pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.45;transform:scale(.8)}}`}</style>
    </span>
  );
}
