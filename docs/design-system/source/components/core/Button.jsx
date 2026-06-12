// Button — labeled pill button. Mirrors the panel's NButton (pill,
// iRadiusM corners, 1px outline, hover lightens the fill). Variants
// extend the single primary form the panel ships with so the system
// can also express neutral and destructive actions (e.g. the Deny /
// Cancel buttons that the panel renders with QtQuick's default style).
import React from "react";
import { Icon } from "./Icon.jsx";

const VARIANTS = {
  primary: { background: "var(--m-primary)", color: "var(--m-on-primary)", border: "var(--m-outline)" },
  neutral: { background: "var(--m-surface-variant)", color: "var(--m-on-surface)", border: "var(--m-outline)" },
  danger:  { background: "var(--m-error)", color: "var(--m-on-error)", border: "var(--m-outline)" },
};

export function Button({
  children,
  icon,
  variant = "primary",
  disabled = false,
  type = "button",
  onClick,
  style = {},
  ...rest
}) {
  const v = VARIANTS[variant] || VARIANTS.primary;
  const [hover, setHover] = React.useState(false);
  return (
    <button
      type={type}
      disabled={disabled}
      onClick={onClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        gap: "var(--space-xs)",
        height: "28px",
        padding: "0 var(--space-l)",
        font: `var(--weight-medium) var(--text-m)/1 var(--font-sans)`,
        color: v.color,
        background: v.background,
        border: `var(--border-width) solid ${v.border}`,
        borderRadius: "var(--radius-input)",
        cursor: disabled ? "default" : "pointer",
        opacity: disabled ? 0.6 : 1,
        filter: hover && !disabled ? "brightness(1.1)" : "none",
        transition: `filter var(--duration-fast) var(--ease-standard), background var(--duration-fast) var(--ease-standard)`,
        whiteSpace: "nowrap",
        ...style,
      }}
      {...rest}
    >
      {icon ? <Icon name={icon} size={15} /> : null}
      {children}
    </button>
  );
}
