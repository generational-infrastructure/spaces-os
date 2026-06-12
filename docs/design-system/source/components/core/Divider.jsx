// Divider — 1px hairline in the outline colour. The panel's NDivider.
import React from "react";

export function Divider({ vertical = false, style = {}, ...rest }) {
  return (
    <div
      role="separator"
      aria-orientation={vertical ? "vertical" : "horizontal"}
      style={{
        background: "var(--m-outline)",
        flexShrink: 0,
        ...(vertical
          ? { width: "var(--border-width)", alignSelf: "stretch" }
          : { height: "var(--border-width)", width: "100%" }),
        ...style,
      }}
      {...rest}
    />
  );
}
