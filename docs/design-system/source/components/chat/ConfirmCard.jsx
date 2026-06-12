// ConfirmCard — inline shell-command approval. From Bubble.qml's
// confirm card: title + monospace command body + Allow/Deny, collapsing
// to a permanent audit line once answered (✓ allowed / ✗ denied) with a
// state-coloured border. Because confirms are owned by the executor,
// any attached client can answer — so it optionally shows WHICH machine
// is asking and, once resolved, where it was answered.
import React from "react";
import { Button } from "../core/Button.jsx";
import { MachineChip } from "../core/MachineChip.jsx";

export function ConfirmCard({
  title = "Run shell command?",
  command = "",
  state = "pending",        // pending | allowed | denied
  machine,                  // { name, color } — optional, the asking machine
  answeredBy,               // e.g. "answered on iPhone" — optional provenance
  onAllow,
  onDeny,
  style = {},
}) {
  const borderColor =
    state === "allowed" ? "var(--m-tertiary)" :
    state === "denied"  ? "var(--m-error)" :
    "var(--m-primary)";

  return (
    <div
      style={{
        background: "var(--m-surface-variant)",
        border: `var(--border-width) solid ${borderColor}`,
        borderRadius: "var(--radius-s)",
        padding: "var(--space-m)",
        display: "flex",
        flexDirection: "column",
        gap: "var(--space-s)",
        ...style,
      }}
    >
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: "var(--space-s)" }}>
        <span style={{ font: `var(--weight-bold) var(--text-m)/1.2 var(--font-sans)`, color: "var(--m-on-surface)" }}>{title}</span>
        {machine ? <MachineChip name={machine.name} color={machine.color} size="sm" /> : null}
      </div>

      <pre
        style={{
          margin: 0,
          background: "var(--m-surface)",
          border: "var(--border-width) solid var(--m-outline)",
          borderRadius: "var(--radius-xs)",
          padding: "var(--space-s) var(--space-m)",
          font: `var(--weight-medium) var(--text-s)/1.5 var(--font-mono)`,
          color: "var(--m-on-surface)",
          whiteSpace: "pre-wrap",
          wordBreak: "break-all",
        }}
      >
        {command}
      </pre>

      {state === "pending" ? (
        <div style={{ display: "flex", justifyContent: "flex-end", gap: "var(--space-s)" }}>
          <Button variant="neutral" onClick={onDeny}>Deny</Button>
          <Button variant="primary" onClick={onAllow}>Allow</Button>
        </div>
      ) : (
        <div style={{ display: "flex", justifyContent: "flex-end", alignItems: "center", gap: "var(--space-s)" }}>
          {answeredBy ? (
            <span style={{ font: `var(--weight-medium) var(--text-xs)/1 var(--font-sans)`, color: "var(--m-on-surface-variant)" }}>{answeredBy}</span>
          ) : null}
          <span style={{ font: `var(--weight-bold) var(--text-s)/1 var(--font-sans)`, color: state === "allowed" ? "var(--m-tertiary)" : "var(--m-error)" }}>
            {state === "allowed" ? "✓ allowed" : "✗ denied"}
          </span>
        </div>
      )}
    </div>
  );
}
