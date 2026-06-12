// TextInput — single-line or multiline (compose) text field. Mirrors
// the panel's NTextInput (surface-variant fill, input radius, outline
// that turns the accent colour on focus). The compose box in the panel
// uses the surface fill + secondary (periwinkle) focus ring, exposed
// here via `tone="compose"`.
import React from "react";

export function TextInput({
  multiline = false,
  tone = "default",        // default | compose
  value,
  onChange,
  placeholder,
  rows = 1,
  style = {},
  inputStyle = {},
  ...rest
}) {
  const [focus, setFocus] = React.useState(false);
  const compose = tone === "compose";
  const focusColor = compose ? "var(--m-secondary)" : "var(--m-primary)";
  const bg = compose ? "var(--m-surface)" : "var(--m-surface-variant)";

  const shared = {
    width: "100%",
    boxSizing: "border-box",
    resize: "none",
    background: "transparent",
    border: "none",
    outline: "none",
    color: "var(--m-on-surface)",
    font: `var(--weight-medium) var(--text-m)/1.4 var(--font-sans)`,
    padding: "var(--space-s) var(--space-m)",
    ...inputStyle,
  };

  return (
    <div
      style={{
        background: bg,
        border: `var(--border-width) solid ${focus ? focusColor : "var(--m-outline)"}`,
        borderRadius: "var(--radius-input)",
        transition: `border-color var(--duration-fast) var(--ease-standard)`,
        display: "flex",
        ...style,
      }}
    >
      {multiline ? (
        <textarea
          rows={rows}
          value={value}
          onChange={onChange}
          placeholder={placeholder}
          onFocus={() => setFocus(true)}
          onBlur={() => setFocus(false)}
          style={shared}
          {...rest}
        />
      ) : (
        <input
          type="text"
          value={value}
          onChange={onChange}
          placeholder={placeholder}
          onFocus={() => setFocus(true)}
          onBlur={() => setFocus(false)}
          style={shared}
          {...rest}
        />
      )}
    </div>
  );
}
