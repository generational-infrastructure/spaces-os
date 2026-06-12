// Bubble — one chat row. Faithful to the panel's Bubble.qml: alignment
// alone signals author (own = right on chartreuse, peer = left on
// surface-variant with a hairline), with optional quoted reply, a
// relative timestamp, an assistant tokens/sec footer, and the delivery
// ladder (🕓 pending → ✓ sent → ✓✓ read, ⚠ on retry). `notification`
// and `thinking` render as bubble-less faded text.
import React from "react";

const ACK = { pending: "🕓", sent: "✓", read: "✓✓", warn: "⚠" };

export function Bubble({
  from = "peer",          // me | peer
  text = "",
  time,
  ack,                    // pending | sent | read | warn  (own messages)
  tps,                    // assistant tokens/sec (peer)
  quote,                  // quoted reply snippet
  variant = "text",       // text | notification | thinking
  streaming = false,
  searchHit = false,
  searchCurrent = false,
  style = {},
}) {
  const mine = from === "me";

  if (variant === "notification") {
    return (
      <div style={{ display: "flex", justifyContent: "center", ...style }}>
        <div style={{ maxWidth: "85%", textAlign: "center", color: "var(--overlay-on-surface-45)", font: `var(--weight-medium) var(--text-m)/1.4 var(--font-sans)` }}>
          {text}
        </div>
      </div>
    );
  }
  if (variant === "thinking") {
    return (
      <div style={{ display: "flex", ...style }}>
        <div style={{ maxWidth: "85%", color: "var(--overlay-on-surface-45)", fontStyle: "italic", font: `italic var(--weight-medium) var(--text-s)/1.5 var(--font-sans)` }}>
          {text || "thinking…"}
        </div>
      </div>
    );
  }

  const ringColor = searchHit ? (searchCurrent ? "var(--m-tertiary)" : "var(--m-secondary)") : null;
  const border = ringColor
    ? `2px solid ${ringColor}`
    : mine ? "none" : "var(--border-width) solid var(--m-outline)";

  return (
    <div style={{ display: "flex", justifyContent: mine ? "flex-end" : "flex-start", ...style }}>
      <div
        style={{
          maxWidth: "85%",
          background: mine ? "var(--m-primary)" : "var(--m-surface-variant)",
          color: mine ? "var(--m-on-primary)" : "var(--m-on-surface)",
          border,
          borderRadius: "var(--radius-s)",
          padding: "var(--space-m)",
          display: "flex",
          flexDirection: "column",
          gap: "var(--space-xxs)",
        }}
      >
        {quote ? (
          <div
            style={{
              background: mine ? "var(--overlay-on-primary-15)" : "var(--overlay-on-surface-08)",
              color: mine ? "var(--overlay-on-primary-60)" : "var(--m-on-surface-variant)",
              borderRadius: "var(--radius-xs)",
              padding: "var(--space-xs) var(--space-s)",
              font: `var(--weight-medium) var(--text-xs)/1.4 var(--font-sans)`,
              whiteSpace: "nowrap",
              overflow: "hidden",
              textOverflow: "ellipsis",
            }}
          >
            ↳ {quote}
          </div>
        ) : null}

        <div style={{ font: `var(--weight-medium) var(--text-m)/1.5 var(--font-sans)`, whiteSpace: "pre-wrap", wordBreak: "break-word" }}>
          {text}
          {streaming ? <span style={{ marginLeft: 2, opacity: 0.7 }}>▍</span> : null}
        </div>

        <div style={{ display: "flex", alignItems: "center", gap: "var(--space-xs)", justifyContent: mine ? "flex-end" : "flex-start" }}>
          {time ? (
            <span style={{ font: `var(--weight-medium) var(--text-xs)/1 var(--font-sans)`, color: mine ? "var(--overlay-on-primary-60)" : "var(--m-on-surface-variant)" }}>{time}</span>
          ) : null}
          {!mine && tps ? (
            <span style={{ font: `var(--weight-medium) var(--text-xs)/1 var(--font-mono)`, color: "var(--m-on-surface-variant)" }}>{tps.toFixed(1)} t/s</span>
          ) : null}
          {mine && ack ? (
            <span style={{ font: `var(--text-s)/1 var(--font-sans)`, color: ack === "warn" ? "var(--m-error)" : "var(--overlay-on-primary-80)" }}>{ACK[ack]}</span>
          ) : null}
        </div>
      </div>
    </div>
  );
}
