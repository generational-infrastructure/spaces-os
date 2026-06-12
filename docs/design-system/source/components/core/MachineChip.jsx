// MachineChip — the recurring identity unit for an executor ("machine"
// in user-facing copy). A machine is recognised by its stable accent
// COLOUR + hostname; reachability is a separate StatusDot so identity
// and live-state never fight for the same signal.
//
//   identity  → the machine's colour tints the hostname (and fills the
//               chip in the `solid` variant, used for the active selection)
//   state     → optional leading StatusDot (online / offline / working)
//
// Use the same colour for a given machine everywhere (tabs, header,
// list rows) so the user pattern-matches "yellow = kiwi" at a glance.
import React from "react";
import { StatusDot } from "./StatusDot.jsx";
import { Icon } from "./Icon.jsx";

const SIZES = {
  sm: { h: 20, font: "var(--text-xs)", pad: "0 var(--space-s)", gap: "var(--space-xs)", dot: 6 },
  md: { h: 26, font: "var(--text-s)", pad: "0 var(--space-s)", gap: "var(--space-xs)", dot: 8 },
};

export function MachineChip({
  name,
  color = "var(--m-primary)",
  status,            // online | offline | working | idle — optional
  relayed = false,   // reached off-LAN via relay
  size = "md",
  variant = "outline", // outline | ghost | solid
  style = {},
  ...rest
}) {
  const s = SIZES[size] || SIZES.md;
  const solid = variant === "solid";
  const bg = solid
    ? color
    : variant === "ghost"
      ? "transparent"
      : "var(--m-surface-variant)";
  const labelColor = solid ? "var(--m-on-primary)" : color;
  const border = variant === "outline" ? "var(--border-width) solid var(--m-outline)" : "var(--border-width) solid transparent";

  return (
    <span
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: s.gap,
        height: `${s.h}px`,
        padding: s.pad,
        background: bg,
        border,
        borderRadius: "var(--radius-input)",
        font: `var(--weight-medium) ${s.font}/1 var(--font-mono)`,
        color: labelColor,
        whiteSpace: "nowrap",
        ...style,
      }}
      {...rest}
    >
      {status ? <StatusDot status={status} size={s.dot} /> : null}
      <span>{name}</span>
      {relayed ? (
        <Icon name="rotate" size={s.dot + 4} style={{ opacity: 0.7 }} title="relayed" />
      ) : null}
    </span>
  );
}
