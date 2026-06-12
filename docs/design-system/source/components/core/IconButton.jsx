// IconButton — square icon-only control. Mirrors the panel's
// NIconButton: surface-variant fill, chartreuse glyph, and a hover
// state that flips the whole chip to the mint hover fill with navy
// ink. Corner radius is min(radius-input, size/2) so small sizes read
// as circles and the default 33px reads as a squircle.
import React from "react";
import { Icon } from "./Icon.jsx";

export function IconButton({
  icon,
  size = 33,
  active = false,
  disabled = false,
  title,
  onClick,
  style = {},
  ...rest
}) {
  const [hover, setHover] = React.useState(false);
  const radius = Math.min(6, size / 2);
  const hovering = hover && !disabled;

  // Active = a "recording / armed" toggle (the voice button turns the
  // chip error-red). Otherwise: rest = surface chip, hover = mint fill.
  let bg, fg, border;
  if (active) {
    bg = "var(--m-error)"; fg = "var(--m-on-error)"; border = "var(--m-error)";
  } else if (hovering) {
    bg = "var(--m-hover)"; fg = "var(--m-on-hover)"; border = "var(--m-outline)";
  } else {
    bg = "var(--m-surface-variant)"; fg = "var(--m-primary)"; border = "var(--m-outline)";
  }

  return (
    <button
      type="button"
      title={title}
      aria-label={title}
      disabled={disabled}
      onClick={onClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        width: `${size}px`,
        height: `${size}px`,
        padding: 0,
        background: bg,
        color: fg,
        border: `var(--border-width) solid ${border}`,
        borderRadius: `${radius}px`,
        cursor: disabled ? "default" : "pointer",
        opacity: disabled ? 0.6 : 1,
        transition: `background var(--duration-fast) var(--ease-standard), color var(--duration-fast) var(--ease-standard)`,
        ...style,
      }}
      {...rest}
    >
      <Icon name={icon} size={Math.max(14, Math.round(size * 0.45))} />
    </button>
  );
}
