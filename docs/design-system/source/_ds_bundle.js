/* @ds-bundle: {"format":3,"namespace":"SpacesOSDesignSystem_2b64aa","components":[{"name":"Bubble","sourcePath":"components/chat/Bubble.jsx"},{"name":"ConfirmCard","sourcePath":"components/chat/ConfirmCard.jsx"},{"name":"Button","sourcePath":"components/core/Button.jsx"},{"name":"Divider","sourcePath":"components/core/Divider.jsx"},{"name":"ICON_PATHS","sourcePath":"components/core/Icon.jsx"},{"name":"Icon","sourcePath":"components/core/Icon.jsx"},{"name":"IconButton","sourcePath":"components/core/IconButton.jsx"},{"name":"MachineChip","sourcePath":"components/core/MachineChip.jsx"},{"name":"StatusDot","sourcePath":"components/core/StatusDot.jsx"},{"name":"TextInput","sourcePath":"components/core/TextInput.jsx"}],"sourceHashes":{"components/chat/Bubble.jsx":"8b403eabde93","components/chat/ConfirmCard.jsx":"0058cfe69a65","components/core/Button.jsx":"0ea137a54600","components/core/Divider.jsx":"a8adf66dc74f","components/core/Icon.jsx":"a7f2002feb90","components/core/IconButton.jsx":"68780ecf1329","components/core/MachineChip.jsx":"d1907ed6c141","components/core/StatusDot.jsx":"449d263b6c70","components/core/TextInput.jsx":"af47f7754227","ui_kits/pwa/ios-frame.jsx":"be3343be4b51","ui_kits/pwa/kit.standalone.jsx":"0b15edb667ac","ui_kits/pwa/pwa.jsx":"dab4c383e246","ui_kits/quickshell-panel/panel.jsx":"182867dfc6e1","ui_kits/shared/kit.jsx":"36cc6ff4aa5b"},"inlinedExternals":[],"unexposedExports":[]} */

(() => {

const __ds_ns = (window.SpacesOSDesignSystem_2b64aa = window.SpacesOSDesignSystem_2b64aa || {});

const __ds_scope = {};

(__ds_ns.__errors = __ds_ns.__errors || []);

// components/chat/Bubble.jsx
try { (() => {
// Bubble — one chat row. Faithful to the panel's Bubble.qml: alignment
// alone signals author (own = right on chartreuse, peer = left on
// surface-variant with a hairline), with optional quoted reply, a
// relative timestamp, an assistant tokens/sec footer, and the delivery
// ladder (🕓 pending → ✓ sent → ✓✓ read, ⚠ on retry). `notification`
// and `thinking` render as bubble-less faded text.

const ACK = {
  pending: "🕓",
  sent: "✓",
  read: "✓✓",
  warn: "⚠"
};
function Bubble({
  from = "peer",
  // me | peer
  text = "",
  time,
  ack,
  // pending | sent | read | warn  (own messages)
  tps,
  // assistant tokens/sec (peer)
  quote,
  // quoted reply snippet
  variant = "text",
  // text | notification | thinking
  streaming = false,
  searchHit = false,
  searchCurrent = false,
  style = {}
}) {
  const mine = from === "me";
  if (variant === "notification") {
    return /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        justifyContent: "center",
        ...style
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        maxWidth: "85%",
        textAlign: "center",
        color: "var(--overlay-on-surface-45)",
        font: `var(--weight-medium) var(--text-m)/1.4 var(--font-sans)`
      }
    }, text));
  }
  if (variant === "thinking") {
    return /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        ...style
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        maxWidth: "85%",
        color: "var(--overlay-on-surface-45)",
        fontStyle: "italic",
        font: `italic var(--weight-medium) var(--text-s)/1.5 var(--font-sans)`
      }
    }, text || "thinking…"));
  }
  const ringColor = searchHit ? searchCurrent ? "var(--m-tertiary)" : "var(--m-secondary)" : null;
  const border = ringColor ? `2px solid ${ringColor}` : mine ? "none" : "var(--border-width) solid var(--m-outline)";
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      justifyContent: mine ? "flex-end" : "flex-start",
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      maxWidth: "85%",
      background: mine ? "var(--m-primary)" : "var(--m-surface-variant)",
      color: mine ? "var(--m-on-primary)" : "var(--m-on-surface)",
      border,
      borderRadius: "var(--radius-s)",
      padding: "var(--space-m)",
      display: "flex",
      flexDirection: "column",
      gap: "var(--space-xxs)"
    }
  }, quote ? /*#__PURE__*/React.createElement("div", {
    style: {
      background: mine ? "var(--overlay-on-primary-15)" : "var(--overlay-on-surface-08)",
      color: mine ? "var(--overlay-on-primary-60)" : "var(--m-on-surface-variant)",
      borderRadius: "var(--radius-xs)",
      padding: "var(--space-xs) var(--space-s)",
      font: `var(--weight-medium) var(--text-xs)/1.4 var(--font-sans)`,
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis"
    }
  }, "\u21B3 ", quote) : null, /*#__PURE__*/React.createElement("div", {
    style: {
      font: `var(--weight-medium) var(--text-m)/1.5 var(--font-sans)`,
      whiteSpace: "pre-wrap",
      wordBreak: "break-word"
    }
  }, text, streaming ? /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 2,
      opacity: 0.7
    }
  }, "\u258D") : null), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: "var(--space-xs)",
      justifyContent: mine ? "flex-end" : "flex-start"
    }
  }, time ? /*#__PURE__*/React.createElement("span", {
    style: {
      font: `var(--weight-medium) var(--text-xs)/1 var(--font-sans)`,
      color: mine ? "var(--overlay-on-primary-60)" : "var(--m-on-surface-variant)"
    }
  }, time) : null, !mine && tps ? /*#__PURE__*/React.createElement("span", {
    style: {
      font: `var(--weight-medium) var(--text-xs)/1 var(--font-mono)`,
      color: "var(--m-on-surface-variant)"
    }
  }, tps.toFixed(1), " t/s") : null, mine && ack ? /*#__PURE__*/React.createElement("span", {
    style: {
      font: `var(--text-s)/1 var(--font-sans)`,
      color: ack === "warn" ? "var(--m-error)" : "var(--overlay-on-primary-80)"
    }
  }, ACK[ack]) : null)));
}
Object.assign(__ds_scope, { Bubble });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/chat/Bubble.jsx", error: String((e && e.message) || e) }); }

// components/core/Divider.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
// Divider — 1px hairline in the outline colour. The panel's NDivider.

function Divider({
  vertical = false,
  style = {},
  ...rest
}) {
  return /*#__PURE__*/React.createElement("div", _extends({
    role: "separator",
    "aria-orientation": vertical ? "vertical" : "horizontal",
    style: {
      background: "var(--m-outline)",
      flexShrink: 0,
      ...(vertical ? {
        width: "var(--border-width)",
        alignSelf: "stretch"
      } : {
        height: "var(--border-width)",
        width: "100%"
      }),
      ...style
    }
  }, rest));
}
Object.assign(__ds_scope, { Divider });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Divider.jsx", error: String((e && e.message) || e) }); }

// components/core/Icon.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
// Icon — Spaces OS iconography.
//
// Tabler Icons (outline), MIT licensed — the exact set vendored in the
// pi-chat panel (programs/pi-chat/icons). 24x24 grid, 2px stroke,
// round caps/joins, drawn in currentColor so the glyph takes the CSS
// `color` of its context. Names match the source SVG filenames.

const ICON_PATHS = {
  "brain": "<path d=\"M15.5 13a3.5 3.5 0 0 0 -3.5 3.5v1a3.5 3.5 0 0 0 7 0v-1.8\"></path>\n  <path d=\"M8.5 13a3.5 3.5 0 0 1 3.5 3.5v1a3.5 3.5 0 0 1 -7 0v-1.8\"></path>\n  <path d=\"M17.5 16a3.5 3.5 0 0 0 0 -7h-.5\"></path>\n  <path d=\"M19 9.3v-2.8a3.5 3.5 0 0 0 -7 0\"></path>\n  <path d=\"M6.5 16a3.5 3.5 0 0 1 0 -7h.5\"></path>\n  <path d=\"M5 9.3v-2.8a3.5 3.5 0 0 1 7 0v10\"></path>",
  "check": "<path d=\"M5 12l5 5l10 -10\"></path>",
  "chevron-down": "<path d=\"M6 9l6 6l6 -6\"></path>",
  "chevron-up": "<path d=\"M6 15l6 -6l6 6\"></path>",
  "corner-down-right": "<path d=\"M6 6v6a3 3 0 0 0 3 3h10l-4 -4m0 8l4 -4\"></path>",
  "database-off": "<path d=\"M12.983 8.978c3.955 -.182 7.017 -1.446 7.017 -2.978c0 -1.657 -3.582 -3 -8 -3c-1.661 0 -3.204 .19 -4.483 .515m-2.783 1.228c-.471 .382 -.734 .808 -.734 1.257c0 1.22 1.944 2.271 4.734 2.74\"></path>\n  <path d=\"M4 6v6c0 1.657 3.582 3 8 3c.986 0 1.93 -.067 2.802 -.19m3.187 -.82c1.251 -.53 2.011 -1.228 2.011 -1.99v-6\"></path>\n  <path d=\"M4 12v6c0 1.657 3.582 3 8 3c3.217 0 5.991 -.712 7.261 -1.74m.739 -3.26v-4\"></path>\n  <path d=\"M3 3l18 18\"></path>",
  "dots-vertical": "<path d=\"M11 12a1 1 0 1 0 2 0a1 1 0 1 0 -2 0\"></path>\n  <path d=\"M11 19a1 1 0 1 0 2 0a1 1 0 1 0 -2 0\"></path>\n  <path d=\"M11 5a1 1 0 1 0 2 0a1 1 0 1 0 -2 0\"></path>",
  "edit": "<path d=\"M7 7h-1a2 2 0 0 0 -2 2v9a2 2 0 0 0 2 2h9a2 2 0 0 0 2 -2v-1\"></path>\n  <path d=\"M20.385 6.585a2.1 2.1 0 0 0 -2.97 -2.97l-8.415 8.385v3h3l8.385 -8.415\"></path>\n  <path d=\"M16 5l3 3\"></path>",
  "eraser": "<path d=\"M19 20h-10.5l-4.21 -4.3a1 1 0 0 1 0 -1.41l10 -10a1 1 0 0 1 1.41 0l5 5a1 1 0 0 1 0 1.41l-9.2 9.3\"></path>\n  <path d=\"M18 13.3l-6.3 -6.3\"></path>",
  "eye-off": "<path d=\"M10.585 10.587a2 2 0 0 0 2.829 2.828\"></path>\n  <path d=\"M16.681 16.673a8.717 8.717 0 0 1 -4.681 1.327c-3.6 0 -6.6 -2 -9 -6c1.272 -2.12 2.712 -3.678 4.32 -4.674m2.86 -1.146a9.055 9.055 0 0 1 1.82 -.18c3.6 0 6.6 2 9 6c-.666 1.11 -1.379 2.067 -2.138 2.87\"></path>\n  <path d=\"M3 3l18 18\"></path>",
  "eye": "<path d=\"M10 12a2 2 0 1 0 4 0a2 2 0 0 0 -4 0\"></path>\n  <path d=\"M21 12c-2.4 4 -5.4 6 -9 6c-3.6 0 -6.6 -2 -9 -6c2.4 -4 5.4 -6 9 -6c3.6 0 6.6 2 9 6\"></path>",
  "gauge": "<path d=\"M3 12a9 9 0 1 0 18 0a9 9 0 1 0 -18 0\"></path>\n  <path d=\"M11 12a1 1 0 1 0 2 0a1 1 0 1 0 -2 0\"></path>\n  <path d=\"M13.41 10.59l2.59 -2.59\"></path>\n  <path d=\"M7 12a5 5 0 0 1 5 -5\"></path>",
  "key": "<path d=\"M16.555 3.843l3.602 3.602a2.877 2.877 0 0 1 0 4.069l-2.643 2.643a2.877 2.877 0 0 1 -4.069 0l-.301 -.301l-6.558 6.558a2 2 0 0 1 -1.239 .578l-.175 .008h-1.172a1 1 0 0 1 -.993 -.883l-.007 -.117v-1.172a2 2 0 0 1 .467 -1.284l.119 -.13l.414 -.414h2v-2h2v-2l2.144 -2.144l-.301 -.301a2.877 2.877 0 0 1 0 -4.069l2.643 -2.643a2.877 2.877 0 0 1 4.069 0\"></path>\n  <path d=\"M15 9h.01\"></path>",
  "message-chatbot": "<path d=\"M18 4a3 3 0 0 1 3 3v8a3 3 0 0 1 -3 3h-5l-5 3v-3h-2a3 3 0 0 1 -3 -3v-8a3 3 0 0 1 3 -3h12\"></path>\n  <path d=\"M9.5 9h.01\"></path>\n  <path d=\"M14.5 9h.01\"></path>\n  <path d=\"M9.5 13a3.5 3.5 0 0 0 5 0\"></path>",
  "message-circle-off": "<path d=\"M8.595 4.577c3.223 -1.176 7.025 -.61 9.65 1.63c2.982 2.543 3.601 6.523 1.636 9.66m-1.908 2.109c-2.787 2.19 -6.89 2.666 -10.273 1.024l-4.7 1l1.3 -3.9c-2.229 -3.296 -1.494 -7.511 1.68 -10.057\"></path>\n  <path d=\"M3 3l18 18\"></path>",
  "message-circle": "<path d=\"M3 20l1.3 -3.9c-2.324 -3.437 -1.426 -7.872 2.1 -10.374c3.526 -2.501 8.59 -2.296 11.845 .48c3.255 2.777 3.695 7.266 1.029 10.501c-2.666 3.235 -7.615 4.215 -11.574 2.293l-4.7 1\"></path>",
  "microphone-off": "<path d=\"M3 3l18 18\"></path>\n  <path d=\"M9 5a3 3 0 0 1 6 0v5a3 3 0 0 1 -.13 .874m-2 2a3 3 0 0 1 -3.87 -2.872v-1\"></path>\n  <path d=\"M5 10a7 7 0 0 0 10.846 5.85m2 -2a6.967 6.967 0 0 0 1.152 -3.85\"></path>\n  <path d=\"M8 21l8 0\"></path>\n  <path d=\"M12 17l0 4\"></path>",
  "microphone": "<path d=\"M9 5a3 3 0 0 1 3 -3a3 3 0 0 1 3 3v5a3 3 0 0 1 -3 3a3 3 0 0 1 -3 -3l0 -5\"></path>\n  <path d=\"M5 10a7 7 0 0 0 14 0\"></path>\n  <path d=\"M8 21l8 0\"></path>\n  <path d=\"M12 17l0 4\"></path>",
  "paperclip": "<path d=\"M15 7l-6.5 6.5a1.5 1.5 0 0 0 3 3l6.5 -6.5a3 3 0 0 0 -6 -6l-6.5 6.5a4.5 4.5 0 0 0 9 9l6.5 -6.5\"></path>",
  "plus": "<path d=\"M12 5l0 14\"></path>\n  <path d=\"M5 12l14 0\"></path>",
  "rotate": "<path d=\"M19.95 11a8 8 0 1 0 -.5 4m.5 5v-5h-5\"></path>",
  "search": "<path d=\"M3 10a7 7 0 1 0 14 0a7 7 0 1 0 -14 0\"></path>\n  <path d=\"M21 21l-6 -6\"></path>",
  "send": "<path d=\"M10 14l11 -11\"></path>\n  <path d=\"M21 3l-6.5 18a.55 .55 0 0 1 -1 0l-3.5 -7l-7 -3.5a.55 .55 0 0 1 0 -1l18 -6.5\"></path>",
  "settings": "<path d=\"M10.325 4.317c.426 -1.756 2.924 -1.756 3.35 0a1.724 1.724 0 0 0 2.573 1.066c1.543 -.94 3.31 .826 2.37 2.37a1.724 1.724 0 0 0 1.065 2.572c1.756 .426 1.756 2.924 0 3.35a1.724 1.724 0 0 0 -1.066 2.573c.94 1.543 -.826 3.31 -2.37 2.37a1.724 1.724 0 0 0 -2.572 1.065c-.426 1.756 -2.924 1.756 -3.35 0a1.724 1.724 0 0 0 -2.573 -1.066c-1.543 .94 -3.31 -.826 -2.37 -2.37a1.724 1.724 0 0 0 -1.065 -2.572c-1.756 -.426 -1.756 -2.924 0 -3.35a1.724 1.724 0 0 0 1.066 -2.573c-.94 -1.543 .826 -3.31 2.37 -2.37c1 .608 2.296 .07 2.572 -1.065\"></path>\n  <path d=\"M9 12a3 3 0 1 0 6 0a3 3 0 0 0 -6 0\"></path>",
  "sparkles": "<path d=\"M16 18a2 2 0 0 1 2 2a2 2 0 0 1 2 -2a2 2 0 0 1 -2 -2a2 2 0 0 1 -2 2zm0 -12a2 2 0 0 1 2 2a2 2 0 0 1 2 -2a2 2 0 0 1 -2 -2a2 2 0 0 1 -2 2zm-7 12a6 6 0 0 1 6 -6a6 6 0 0 1 -6 -6a6 6 0 0 1 -6 6a6 6 0 0 1 6 6z\"></path>",
  "x": "<path d=\"M18 6l-12 12\"></path>\n  <path d=\"M6 6l12 12\"></path>"
};
function Icon({
  name,
  size = 20,
  strokeWidth = 2,
  className = "",
  style = {},
  title,
  ...rest
}) {
  const inner = ICON_PATHS[name];
  if (inner === undefined) {
    if (typeof console !== "undefined") console.warn("Icon: unknown name", name);
    return null;
  }
  return /*#__PURE__*/React.createElement("svg", _extends({
    xmlns: "http://www.w3.org/2000/svg",
    width: size,
    height: size,
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: strokeWidth,
    strokeLinecap: "round",
    strokeLinejoin: "round",
    className: className,
    style: {
      display: "block",
      flexShrink: 0,
      ...style
    },
    role: title ? "img" : "presentation",
    "aria-label": title,
    "aria-hidden": title ? undefined : true,
    dangerouslySetInnerHTML: {
      __html: inner
    }
  }, rest));
}
Object.assign(__ds_scope, { ICON_PATHS, Icon });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Icon.jsx", error: String((e && e.message) || e) }); }

// components/core/Button.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
// Button — labeled pill button. Mirrors the panel's NButton (pill,
// iRadiusM corners, 1px outline, hover lightens the fill). Variants
// extend the single primary form the panel ships with so the system
// can also express neutral and destructive actions (e.g. the Deny /
// Cancel buttons that the panel renders with QtQuick's default style).

const VARIANTS = {
  primary: {
    background: "var(--m-primary)",
    color: "var(--m-on-primary)",
    border: "var(--m-outline)"
  },
  neutral: {
    background: "var(--m-surface-variant)",
    color: "var(--m-on-surface)",
    border: "var(--m-outline)"
  },
  danger: {
    background: "var(--m-error)",
    color: "var(--m-on-error)",
    border: "var(--m-outline)"
  }
};
function Button({
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
  return /*#__PURE__*/React.createElement("button", _extends({
    type: type,
    disabled: disabled,
    onClick: onClick,
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    style: {
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
      ...style
    }
  }, rest), icon ? /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: icon,
    size: 15
  }) : null, children);
}
Object.assign(__ds_scope, { Button });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/Button.jsx", error: String((e && e.message) || e) }); }

// components/core/IconButton.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
// IconButton — square icon-only control. Mirrors the panel's
// NIconButton: surface-variant fill, chartreuse glyph, and a hover
// state that flips the whole chip to the mint hover fill with navy
// ink. Corner radius is min(radius-input, size/2) so small sizes read
// as circles and the default 33px reads as a squircle.

function IconButton({
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
    bg = "var(--m-error)";
    fg = "var(--m-on-error)";
    border = "var(--m-error)";
  } else if (hovering) {
    bg = "var(--m-hover)";
    fg = "var(--m-on-hover)";
    border = "var(--m-outline)";
  } else {
    bg = "var(--m-surface-variant)";
    fg = "var(--m-primary)";
    border = "var(--m-outline)";
  }
  return /*#__PURE__*/React.createElement("button", _extends({
    type: "button",
    title: title,
    "aria-label": title,
    disabled: disabled,
    onClick: onClick,
    onMouseEnter: () => setHover(true),
    onMouseLeave: () => setHover(false),
    style: {
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
      ...style
    }
  }, rest), /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: icon,
    size: Math.max(14, Math.round(size * 0.45))
  }));
}
Object.assign(__ds_scope, { IconButton });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/IconButton.jsx", error: String((e && e.message) || e) }); }

// components/core/StatusDot.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
// StatusDot — the tiny live-state indicator used throughout both
// clients (the panel's relayDot, session unread marks, machine
// reachability). Colour encodes state; `working` softly pulses.

const STATUS = {
  online: {
    color: "var(--m-tertiary)",
    pulse: false
  },
  // reachable
  offline: {
    color: "var(--m-error)",
    pulse: false
  },
  // unreachable
  working: {
    color: "var(--m-primary)",
    pulse: true
  },
  // agent busy
  idle: {
    color: "var(--m-on-surface-variant)",
    pulse: false
  },
  error: {
    color: "var(--m-error)",
    pulse: false
  }
};
function StatusDot({
  status = "online",
  size = 8,
  style = {},
  ...rest
}) {
  const s = STATUS[status] || STATUS.idle;
  return /*#__PURE__*/React.createElement("span", _extends({
    role: "status",
    "aria-label": status,
    style: {
      display: "inline-block",
      width: `${size}px`,
      height: `${size}px`,
      borderRadius: "50%",
      background: s.color,
      flexShrink: 0,
      animation: s.pulse ? `sos-pulse 1.4s var(--ease-standard) infinite` : "none",
      ...style
    }
  }, rest), /*#__PURE__*/React.createElement("style", null, `@keyframes sos-pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.45;transform:scale(.8)}}`));
}
Object.assign(__ds_scope, { StatusDot });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/StatusDot.jsx", error: String((e && e.message) || e) }); }

// components/core/MachineChip.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
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

const SIZES = {
  sm: {
    h: 20,
    font: "var(--text-xs)",
    pad: "0 var(--space-s)",
    gap: "var(--space-xs)",
    dot: 6
  },
  md: {
    h: 26,
    font: "var(--text-s)",
    pad: "0 var(--space-s)",
    gap: "var(--space-xs)",
    dot: 8
  }
};
function MachineChip({
  name,
  color = "var(--m-primary)",
  status,
  // online | offline | working | idle — optional
  relayed = false,
  // reached off-LAN via relay
  size = "md",
  variant = "outline",
  // outline | ghost | solid
  style = {},
  ...rest
}) {
  const s = SIZES[size] || SIZES.md;
  const solid = variant === "solid";
  const bg = solid ? color : variant === "ghost" ? "transparent" : "var(--m-surface-variant)";
  const labelColor = solid ? "var(--m-on-primary)" : color;
  const border = variant === "outline" ? "var(--border-width) solid var(--m-outline)" : "var(--border-width) solid transparent";
  return /*#__PURE__*/React.createElement("span", _extends({
    style: {
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
      ...style
    }
  }, rest), status ? /*#__PURE__*/React.createElement(__ds_scope.StatusDot, {
    status: status,
    size: s.dot
  }) : null, /*#__PURE__*/React.createElement("span", null, name), relayed ? /*#__PURE__*/React.createElement(__ds_scope.Icon, {
    name: "rotate",
    size: s.dot + 4,
    style: {
      opacity: 0.7
    },
    title: "relayed"
  }) : null);
}
Object.assign(__ds_scope, { MachineChip });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/MachineChip.jsx", error: String((e && e.message) || e) }); }

// components/chat/ConfirmCard.jsx
try { (() => {
// ConfirmCard — inline shell-command approval. From Bubble.qml's
// confirm card: title + monospace command body + Allow/Deny, collapsing
// to a permanent audit line once answered (✓ allowed / ✗ denied) with a
// state-coloured border. Because confirms are owned by the executor,
// any attached client can answer — so it optionally shows WHICH machine
// is asking and, once resolved, where it was answered.

function ConfirmCard({
  title = "Run shell command?",
  command = "",
  state = "pending",
  // pending | allowed | denied
  machine,
  // { name, color } — optional, the asking machine
  answeredBy,
  // e.g. "answered on iPhone" — optional provenance
  onAllow,
  onDeny,
  style = {}
}) {
  const borderColor = state === "allowed" ? "var(--m-tertiary)" : state === "denied" ? "var(--m-error)" : "var(--m-primary)";
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: "var(--m-surface-variant)",
      border: `var(--border-width) solid ${borderColor}`,
      borderRadius: "var(--radius-s)",
      padding: "var(--space-m)",
      display: "flex",
      flexDirection: "column",
      gap: "var(--space-s)",
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      justifyContent: "space-between",
      gap: "var(--space-s)"
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      font: `var(--weight-bold) var(--text-m)/1.2 var(--font-sans)`,
      color: "var(--m-on-surface)"
    }
  }, title), machine ? /*#__PURE__*/React.createElement(__ds_scope.MachineChip, {
    name: machine.name,
    color: machine.color,
    size: "sm"
  }) : null), /*#__PURE__*/React.createElement("pre", {
    style: {
      margin: 0,
      background: "var(--m-surface)",
      border: "var(--border-width) solid var(--m-outline)",
      borderRadius: "var(--radius-xs)",
      padding: "var(--space-s) var(--space-m)",
      font: `var(--weight-medium) var(--text-s)/1.5 var(--font-mono)`,
      color: "var(--m-on-surface)",
      whiteSpace: "pre-wrap",
      wordBreak: "break-all"
    }
  }, command), state === "pending" ? /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      justifyContent: "flex-end",
      gap: "var(--space-s)"
    }
  }, /*#__PURE__*/React.createElement(__ds_scope.Button, {
    variant: "neutral",
    onClick: onDeny
  }, "Deny"), /*#__PURE__*/React.createElement(__ds_scope.Button, {
    variant: "primary",
    onClick: onAllow
  }, "Allow")) : /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      justifyContent: "flex-end",
      alignItems: "center",
      gap: "var(--space-s)"
    }
  }, answeredBy ? /*#__PURE__*/React.createElement("span", {
    style: {
      font: `var(--weight-medium) var(--text-xs)/1 var(--font-sans)`,
      color: "var(--m-on-surface-variant)"
    }
  }, answeredBy) : null, /*#__PURE__*/React.createElement("span", {
    style: {
      font: `var(--weight-bold) var(--text-s)/1 var(--font-sans)`,
      color: state === "allowed" ? "var(--m-tertiary)" : "var(--m-error)"
    }
  }, state === "allowed" ? "✓ allowed" : "✗ denied")));
}
Object.assign(__ds_scope, { ConfirmCard });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/chat/ConfirmCard.jsx", error: String((e && e.message) || e) }); }

// components/core/TextInput.jsx
try { (() => {
function _extends() { return _extends = Object.assign ? Object.assign.bind() : function (n) { for (var e = 1; e < arguments.length; e++) { var t = arguments[e]; for (var r in t) ({}).hasOwnProperty.call(t, r) && (n[r] = t[r]); } return n; }, _extends.apply(null, arguments); }
// TextInput — single-line or multiline (compose) text field. Mirrors
// the panel's NTextInput (surface-variant fill, input radius, outline
// that turns the accent colour on focus). The compose box in the panel
// uses the surface fill + secondary (periwinkle) focus ring, exposed
// here via `tone="compose"`.

function TextInput({
  multiline = false,
  tone = "default",
  // default | compose
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
    ...inputStyle
  };
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: bg,
      border: `var(--border-width) solid ${focus ? focusColor : "var(--m-outline)"}`,
      borderRadius: "var(--radius-input)",
      transition: `border-color var(--duration-fast) var(--ease-standard)`,
      display: "flex",
      ...style
    }
  }, multiline ? /*#__PURE__*/React.createElement("textarea", _extends({
    rows: rows,
    value: value,
    onChange: onChange,
    placeholder: placeholder,
    onFocus: () => setFocus(true),
    onBlur: () => setFocus(false),
    style: shared
  }, rest)) : /*#__PURE__*/React.createElement("input", _extends({
    type: "text",
    value: value,
    onChange: onChange,
    placeholder: placeholder,
    onFocus: () => setFocus(true),
    onBlur: () => setFocus(false),
    style: shared
  }, rest)));
}
Object.assign(__ds_scope, { TextInput });
})(); } catch (e) { __ds_ns.__errors.push({ path: "components/core/TextInput.jsx", error: String((e && e.message) || e) }); }

// ui_kits/pwa/ios-frame.jsx
try { (() => {
// @ds-adherence-ignore -- omelette starter scaffold (raw elements/hex/px by design)

/* BEGIN USAGE */
// iOS.jsx — Simplified iOS 26 (Liquid Glass) device frame
// Based on the iOS 26 UI Kit + Figma status bar spec. No assets, no deps.
// Exports (to window): IOSDevice, IOSStatusBar, IOSNavBar, IOSGlassPill, IOSList, IOSListRow, IOSKeyboard
//
// Usage — wrap your screen content in <IOSDevice> to get the bezel, status bar
// and home indicator (props: title, dark, keyboard):
//
//   <IOSDevice title="Settings">
//     ...your screen content...
//   </IOSDevice>
//   <IOSDevice dark title="Search" keyboard>…</IOSDevice>
/* END USAGE */

// ─────────────────────────────────────────────────────────────
// Status bar
// ─────────────────────────────────────────────────────────────
function IOSStatusBar({
  dark = false,
  time = '9:41'
}) {
  const c = dark ? '#fff' : '#000';
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 154,
      alignItems: 'center',
      justifyContent: 'center',
      padding: '21px 24px 19px',
      boxSizing: 'border-box',
      position: 'relative',
      zIndex: 20,
      width: '100%'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      height: 22,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      paddingTop: 1.5
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: '-apple-system, "SF Pro", system-ui',
      fontWeight: 590,
      fontSize: 17,
      lineHeight: '22px',
      color: c
    }
  }, time)), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      height: 22,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      gap: 7,
      paddingTop: 1,
      paddingRight: 1
    }
  }, /*#__PURE__*/React.createElement("svg", {
    width: "19",
    height: "12",
    viewBox: "0 0 19 12"
  }, /*#__PURE__*/React.createElement("rect", {
    x: "0",
    y: "7.5",
    width: "3.2",
    height: "4.5",
    rx: "0.7",
    fill: c
  }), /*#__PURE__*/React.createElement("rect", {
    x: "4.8",
    y: "5",
    width: "3.2",
    height: "7",
    rx: "0.7",
    fill: c
  }), /*#__PURE__*/React.createElement("rect", {
    x: "9.6",
    y: "2.5",
    width: "3.2",
    height: "9.5",
    rx: "0.7",
    fill: c
  }), /*#__PURE__*/React.createElement("rect", {
    x: "14.4",
    y: "0",
    width: "3.2",
    height: "12",
    rx: "0.7",
    fill: c
  })), /*#__PURE__*/React.createElement("svg", {
    width: "17",
    height: "12",
    viewBox: "0 0 17 12"
  }, /*#__PURE__*/React.createElement("path", {
    d: "M8.5 3.2C10.8 3.2 12.9 4.1 14.4 5.6L15.5 4.5C13.7 2.7 11.2 1.5 8.5 1.5C5.8 1.5 3.3 2.7 1.5 4.5L2.6 5.6C4.1 4.1 6.2 3.2 8.5 3.2Z",
    fill: c
  }), /*#__PURE__*/React.createElement("path", {
    d: "M8.5 6.8C9.9 6.8 11.1 7.3 12 8.2L13.1 7.1C11.8 5.9 10.2 5.1 8.5 5.1C6.8 5.1 5.2 5.9 3.9 7.1L5 8.2C5.9 7.3 7.1 6.8 8.5 6.8Z",
    fill: c
  }), /*#__PURE__*/React.createElement("circle", {
    cx: "8.5",
    cy: "10.5",
    r: "1.5",
    fill: c
  })), /*#__PURE__*/React.createElement("svg", {
    width: "27",
    height: "13",
    viewBox: "0 0 27 13"
  }, /*#__PURE__*/React.createElement("rect", {
    x: "0.5",
    y: "0.5",
    width: "23",
    height: "12",
    rx: "3.5",
    stroke: c,
    strokeOpacity: "0.35",
    fill: "none"
  }), /*#__PURE__*/React.createElement("rect", {
    x: "2",
    y: "2",
    width: "20",
    height: "9",
    rx: "2",
    fill: c
  }), /*#__PURE__*/React.createElement("path", {
    d: "M25 4.5V8.5C25.8 8.2 26.5 7.2 26.5 6.5C26.5 5.8 25.8 4.8 25 4.5Z",
    fill: c,
    fillOpacity: "0.4"
  }))));
}

// ─────────────────────────────────────────────────────────────
// Liquid glass pill — blur + tint + shine
// ─────────────────────────────────────────────────────────────
function IOSGlassPill({
  children,
  dark = false,
  style = {}
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      height: 44,
      minWidth: 44,
      borderRadius: 9999,
      position: 'relative',
      overflow: 'hidden',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      boxShadow: dark ? '0 2px 6px rgba(0,0,0,0.35), 0 6px 16px rgba(0,0,0,0.2)' : '0 1px 3px rgba(0,0,0,0.07), 0 3px 10px rgba(0,0,0,0.06)',
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      inset: 0,
      borderRadius: 9999,
      backdropFilter: 'blur(12px) saturate(180%)',
      WebkitBackdropFilter: 'blur(12px) saturate(180%)',
      background: dark ? 'rgba(120,120,128,0.28)' : 'rgba(255,255,255,0.5)'
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      inset: 0,
      borderRadius: 9999,
      boxShadow: dark ? 'inset 1.5px 1.5px 1px rgba(255,255,255,0.15), inset -1px -1px 1px rgba(255,255,255,0.08)' : 'inset 1.5px 1.5px 1px rgba(255,255,255,0.7), inset -1px -1px 1px rgba(255,255,255,0.4)',
      border: dark ? '0.5px solid rgba(255,255,255,0.15)' : '0.5px solid rgba(0,0,0,0.06)'
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      zIndex: 1,
      display: 'flex',
      alignItems: 'center',
      padding: '0 4px'
    }
  }, children));
}

// ─────────────────────────────────────────────────────────────
// Navigation bar — glass pills + large title
// ─────────────────────────────────────────────────────────────
function IOSNavBar({
  title = 'Title',
  dark = false,
  trailingIcon = true
}) {
  const muted = dark ? 'rgba(255,255,255,0.6)' : '#404040';
  const text = dark ? '#fff' : '#000';
  const pillIcon = content => /*#__PURE__*/React.createElement(IOSGlassPill, {
    dark: dark
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      width: 36,
      height: 36,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center'
    }
  }, content));
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 10,
      paddingTop: 62,
      paddingBottom: 10,
      position: 'relative',
      zIndex: 5
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      padding: '0 16px'
    }
  }, pillIcon(/*#__PURE__*/React.createElement("svg", {
    width: "12",
    height: "20",
    viewBox: "0 0 12 20",
    fill: "none",
    style: {
      marginLeft: -1
    }
  }, /*#__PURE__*/React.createElement("path", {
    d: "M10 2L2 10l8 8",
    stroke: muted,
    strokeWidth: "2.5",
    strokeLinecap: "round",
    strokeLinejoin: "round"
  }))), trailingIcon && pillIcon(/*#__PURE__*/React.createElement("svg", {
    width: "22",
    height: "6",
    viewBox: "0 0 22 6"
  }, /*#__PURE__*/React.createElement("circle", {
    cx: "3",
    cy: "3",
    r: "2.5",
    fill: muted
  }), /*#__PURE__*/React.createElement("circle", {
    cx: "11",
    cy: "3",
    r: "2.5",
    fill: muted
  }), /*#__PURE__*/React.createElement("circle", {
    cx: "19",
    cy: "3",
    r: "2.5",
    fill: muted
  })))), /*#__PURE__*/React.createElement("div", {
    style: {
      padding: '0 16px',
      fontFamily: '-apple-system, system-ui',
      fontSize: 34,
      fontWeight: 700,
      lineHeight: '41px',
      color: text,
      letterSpacing: 0.4
    }
  }, title));
}

// ─────────────────────────────────────────────────────────────
// Grouped list (inset card, r:26) + row (52px)
// ─────────────────────────────────────────────────────────────
function IOSListRow({
  title,
  detail,
  icon,
  chevron = true,
  isLast = false,
  dark = false
}) {
  const text = dark ? '#fff' : '#000';
  const sec = dark ? 'rgba(235,235,245,0.6)' : 'rgba(60,60,67,0.6)';
  const ter = dark ? 'rgba(235,235,245,0.3)' : 'rgba(60,60,67,0.3)';
  const sep = dark ? 'rgba(84,84,88,0.65)' : 'rgba(60,60,67,0.12)';
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      alignItems: 'center',
      minHeight: 52,
      padding: '0 16px',
      position: 'relative',
      fontFamily: '-apple-system, system-ui',
      fontSize: 17,
      letterSpacing: -0.43
    }
  }, icon && /*#__PURE__*/React.createElement("div", {
    style: {
      width: 30,
      height: 30,
      borderRadius: 7,
      background: icon,
      marginRight: 12,
      flexShrink: 0
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      color: text
    }
  }, title), detail && /*#__PURE__*/React.createElement("span", {
    style: {
      color: sec,
      marginRight: 6
    }
  }, detail), chevron && /*#__PURE__*/React.createElement("svg", {
    width: "8",
    height: "14",
    viewBox: "0 0 8 14",
    style: {
      flexShrink: 0
    }
  }, /*#__PURE__*/React.createElement("path", {
    d: "M1 1l6 6-6 6",
    stroke: ter,
    strokeWidth: "2",
    fill: "none",
    strokeLinecap: "round",
    strokeLinejoin: "round"
  })), !isLast && /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      bottom: 0,
      right: 0,
      left: icon ? 58 : 16,
      height: 0.5,
      background: sep
    }
  }));
}
function IOSList({
  header,
  children,
  dark = false
}) {
  const hc = dark ? 'rgba(235,235,245,0.6)' : 'rgba(60,60,67,0.6)';
  const bg = dark ? '#1C1C1E' : '#fff';
  return /*#__PURE__*/React.createElement("div", null, header && /*#__PURE__*/React.createElement("div", {
    style: {
      fontFamily: '-apple-system, system-ui',
      fontSize: 13,
      color: hc,
      textTransform: 'uppercase',
      padding: '8px 36px 6px',
      letterSpacing: -0.08
    }
  }, header), /*#__PURE__*/React.createElement("div", {
    style: {
      background: bg,
      borderRadius: 26,
      margin: '0 16px',
      overflow: 'hidden'
    }
  }, children));
}

// ─────────────────────────────────────────────────────────────
// Device frame
// ─────────────────────────────────────────────────────────────
function IOSDevice({
  children,
  width = 402,
  height = 874,
  dark = false,
  title,
  keyboard = false
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      width,
      height,
      borderRadius: 48,
      overflow: 'hidden',
      position: 'relative',
      background: dark ? '#000' : '#F2F2F7',
      boxShadow: '0 40px 80px rgba(0,0,0,0.18), 0 0 0 1px rgba(0,0,0,0.12)',
      fontFamily: '-apple-system, system-ui, sans-serif',
      WebkitFontSmoothing: 'antialiased'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      top: 11,
      left: '50%',
      transform: 'translateX(-50%)',
      width: 126,
      height: 37,
      borderRadius: 24,
      background: '#000',
      zIndex: 50
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      top: 0,
      left: 0,
      right: 0,
      zIndex: 10
    }
  }, /*#__PURE__*/React.createElement(IOSStatusBar, {
    dark: dark
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      height: '100%',
      display: 'flex',
      flexDirection: 'column'
    }
  }, title !== undefined && /*#__PURE__*/React.createElement(IOSNavBar, {
    title: title,
    dark: dark
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      overflow: 'auto'
    }
  }, children), keyboard && /*#__PURE__*/React.createElement(IOSKeyboard, {
    dark: dark
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      bottom: 0,
      left: 0,
      right: 0,
      zIndex: 60,
      height: 34,
      display: 'flex',
      justifyContent: 'center',
      alignItems: 'flex-end',
      paddingBottom: 8,
      pointerEvents: 'none'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      width: 139,
      height: 5,
      borderRadius: 100,
      background: dark ? 'rgba(255,255,255,0.7)' : 'rgba(0,0,0,0.25)'
    }
  })));
}

// ─────────────────────────────────────────────────────────────
// Keyboard — iOS 26 liquid glass
// ─────────────────────────────────────────────────────────────
function IOSKeyboard({
  dark = false
}) {
  const glyph = dark ? 'rgba(255,255,255,0.7)' : '#595959';
  const sugg = dark ? 'rgba(255,255,255,0.6)' : '#333';
  const keyBg = dark ? 'rgba(255,255,255,0.22)' : 'rgba(255,255,255,0.85)';

  // special-key icons
  const icons = {
    shift: /*#__PURE__*/React.createElement("svg", {
      width: "19",
      height: "17",
      viewBox: "0 0 19 17"
    }, /*#__PURE__*/React.createElement("path", {
      d: "M9.5 1L1 9.5h4.5V16h8V9.5H18L9.5 1z",
      fill: glyph
    })),
    del: /*#__PURE__*/React.createElement("svg", {
      width: "23",
      height: "17",
      viewBox: "0 0 23 17"
    }, /*#__PURE__*/React.createElement("path", {
      d: "M7 1h13a2 2 0 012 2v11a2 2 0 01-2 2H7l-6-7.5L7 1z",
      fill: "none",
      stroke: glyph,
      strokeWidth: "1.6",
      strokeLinejoin: "round"
    }), /*#__PURE__*/React.createElement("path", {
      d: "M10 5l7 7M17 5l-7 7",
      stroke: glyph,
      strokeWidth: "1.6",
      strokeLinecap: "round"
    })),
    ret: /*#__PURE__*/React.createElement("svg", {
      width: "20",
      height: "14",
      viewBox: "0 0 20 14"
    }, /*#__PURE__*/React.createElement("path", {
      d: "M18 1v6H4m0 0l4-4M4 7l4 4",
      fill: "none",
      stroke: "#fff",
      strokeWidth: "1.8",
      strokeLinecap: "round",
      strokeLinejoin: "round"
    }))
  };
  const key = (content, {
    w,
    flex,
    ret,
    fs = 25,
    k
  } = {}) => /*#__PURE__*/React.createElement("div", {
    key: k,
    style: {
      height: 42,
      borderRadius: 8.5,
      flex: flex ? 1 : undefined,
      width: w,
      minWidth: 0,
      background: ret ? '#08f' : keyBg,
      boxShadow: '0 1px 0 rgba(0,0,0,0.075)',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      fontFamily: '-apple-system, "SF Compact", system-ui',
      fontSize: fs,
      fontWeight: 458,
      color: ret ? '#fff' : glyph
    }
  }, content);
  const row = (keys, pad = 0) => /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 6.5,
      justifyContent: 'center',
      padding: `0 ${pad}px`
    }
  }, keys.map(l => key(l, {
    flex: true,
    k: l
  })));
  return /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'relative',
      zIndex: 15,
      borderRadius: 27,
      overflow: 'hidden',
      padding: '11px 0 2px',
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'center',
      boxShadow: dark ? '0 -2px 20px rgba(0,0,0,0.09)' : '0 -1px 6px rgba(0,0,0,0.018), 0 -3px 20px rgba(0,0,0,0.012)'
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      inset: 0,
      borderRadius: 27,
      backdropFilter: 'blur(12px) saturate(180%)',
      WebkitBackdropFilter: 'blur(12px) saturate(180%)',
      background: dark ? 'rgba(120,120,128,0.14)' : 'rgba(255,255,255,0.25)'
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: 'absolute',
      inset: 0,
      borderRadius: 27,
      boxShadow: dark ? 'inset 1.5px 1.5px 1px rgba(255,255,255,0.15)' : 'inset 1.5px 1.5px 1px rgba(255,255,255,0.7), inset -1px -1px 1px rgba(255,255,255,0.4)',
      border: dark ? '0.5px solid rgba(255,255,255,0.15)' : '0.5px solid rgba(0,0,0,0.06)',
      pointerEvents: 'none'
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 20,
      alignItems: 'center',
      padding: '8px 22px 13px',
      width: '100%',
      boxSizing: 'border-box',
      position: 'relative'
    }
  }, ['"The"', 'the', 'to'].map((w, i) => /*#__PURE__*/React.createElement(React.Fragment, {
    key: i
  }, i > 0 && /*#__PURE__*/React.createElement("div", {
    style: {
      width: 1,
      height: 25,
      background: '#ccc',
      opacity: 0.3
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      textAlign: 'center',
      fontFamily: '-apple-system, system-ui',
      fontSize: 17,
      color: sugg,
      letterSpacing: -0.43,
      lineHeight: '22px'
    }
  }, w)))), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      flexDirection: 'column',
      gap: 13,
      padding: '0 6.5px',
      width: '100%',
      boxSizing: 'border-box',
      position: 'relative'
    }
  }, row(['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p']), row(['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'], 20), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 14.25,
      alignItems: 'center'
    }
  }, key(icons.shift, {
    w: 45,
    k: 'shift'
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 6.5,
      flex: 1
    }
  }, ['z', 'x', 'c', 'v', 'b', 'n', 'm'].map(l => key(l, {
    flex: true,
    k: l
  }))), key(icons.del, {
    w: 45,
    k: 'del'
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      display: 'flex',
      gap: 6,
      alignItems: 'center'
    }
  }, key('ABC', {
    w: 92.25,
    fs: 18,
    k: 'abc'
  }), key('', {
    flex: true,
    k: 'space'
  }), key(icons.ret, {
    w: 92.25,
    ret: true,
    k: 'ret'
  }))), /*#__PURE__*/React.createElement("div", {
    style: {
      height: 56,
      width: '100%',
      position: 'relative'
    }
  }));
}
Object.assign(window, {
  IOSDevice,
  IOSStatusBar,
  IOSNavBar,
  IOSGlassPill,
  IOSList,
  IOSListRow,
  IOSKeyboard
});
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/pwa/ios-frame.jsx", error: String((e && e.message) || e) }); }

// ui_kits/pwa/kit.standalone.jsx
try { (() => {
// Shared Spaces OS kit components for the UI-kit prototypes (panel + PWA).
// These mirror the design-system primitives 1:1 visually but are
// self-contained so the click-through kits render without the compiled
// bundle. All driven by the token CSS variables from styles.css.
// Exposed on window.SOS for the per-kit Babel scripts.
const {
  useState,
  useEffect,
  useRef
} = React;

/* ---------- Icon (runtime-inlined Tabler SVG, recolours via color) ---------- */
const _iconCache = {};
function Icon({
  name,
  size = 20,
  color,
  style = {},
  strokeWidth
}) {
  const [svg, setSvg] = useState(_iconCache[name] || "");
  useEffect(() => {
    let live = true;
    if (_iconCache[name]) {
      setSvg(_iconCache[name]);
      return;
    }
    fetch(window.__resources && window.__resources[name] || `../../assets/icons/${name}.svg`).then(r => r.text()).then(t => {
      if (strokeWidth) t = t.replace(/stroke-width="2"/, `stroke-width="${strokeWidth}"`);
      _iconCache[name] = t;
      if (live) setSvg(t);
    }).catch(() => {});
    return () => {
      live = false;
    };
  }, [name]);
  return /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    style: {
      display: "inline-flex",
      width: size,
      height: size,
      color: color || "currentColor",
      flexShrink: 0,
      ...style
    },
    ref: el => {
      if (el && svg) {
        const s = el.querySelector("svg");
        if (!s || s.dataset.n !== name) {
          el.innerHTML = svg;
          const ns = el.querySelector("svg");
          if (ns) {
            ns.setAttribute("width", size);
            ns.setAttribute("height", size);
            ns.style.display = "block";
            ns.dataset.n = name;
          }
        }
      }
    }
  });
}

/* ---------- StatusDot ---------- */
const DOT = {
  online: {
    c: "var(--m-tertiary)",
    pulse: false
  },
  offline: {
    c: "var(--m-error)",
    pulse: false
  },
  working: {
    c: "var(--m-primary)",
    pulse: true
  },
  idle: {
    c: "var(--m-on-surface-variant)",
    pulse: false
  }
};
function StatusDot({
  status = "online",
  size = 8,
  style = {}
}) {
  const s = DOT[status] || DOT.idle;
  return /*#__PURE__*/React.createElement("span", {
    style: {
      display: "inline-block",
      width: size,
      height: size,
      borderRadius: "50%",
      background: s.c,
      flexShrink: 0,
      animation: s.pulse ? "sos-pulse 1.4s var(--ease-standard) infinite" : "none",
      ...style
    }
  });
}

/* ---------- MachineChip ---------- */
function MachineChip({
  name,
  color = "var(--m-primary)",
  status,
  relayed,
  size = "md",
  variant = "outline",
  style = {},
  onClick
}) {
  const dim = size === "sm" ? {
    h: 20,
    f: "var(--text-xs)",
    dot: 6
  } : {
    h: 26,
    f: "var(--text-s)",
    dot: 8
  };
  const solid = variant === "solid";
  const bg = solid ? color : variant === "ghost" ? "transparent" : "var(--m-surface-variant)";
  const label = solid ? "var(--m-on-primary)" : color;
  const border = variant === "outline" ? "var(--border-width) solid var(--m-outline)" : "var(--border-width) solid transparent";
  return /*#__PURE__*/React.createElement("span", {
    onClick: onClick,
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: "var(--space-xs)",
      height: dim.h,
      padding: "0 var(--space-s)",
      background: bg,
      border,
      borderRadius: "var(--radius-input)",
      font: `var(--weight-medium) ${dim.f}/1 var(--font-mono)`,
      color: label,
      whiteSpace: "nowrap",
      cursor: onClick ? "pointer" : "default",
      ...style
    }
  }, status ? /*#__PURE__*/React.createElement(StatusDot, {
    status: status,
    size: dim.dot
  }) : null, /*#__PURE__*/React.createElement("span", null, name), relayed ? /*#__PURE__*/React.createElement(Icon, {
    name: "rotate",
    size: dim.dot + 4,
    style: {
      opacity: 0.7
    }
  }) : null);
}

/* ---------- Button ---------- */
const BTN = {
  primary: {
    background: "var(--m-primary)",
    color: "var(--m-on-primary)"
  },
  neutral: {
    background: "var(--m-surface-variant)",
    color: "var(--m-on-surface)"
  },
  danger: {
    background: "var(--m-error)",
    color: "var(--m-on-error)"
  }
};
function Button({
  children,
  icon,
  variant = "primary",
  disabled,
  onClick,
  style = {}
}) {
  const v = BTN[variant] || BTN.primary;
  const [h, setH] = useState(false);
  return /*#__PURE__*/React.createElement("button", {
    type: "button",
    disabled: disabled,
    onClick: onClick,
    onMouseEnter: () => setH(true),
    onMouseLeave: () => setH(false),
    style: {
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      gap: "var(--space-xs)",
      height: 28,
      padding: "0 var(--space-l)",
      font: `var(--weight-medium) var(--text-m)/1 var(--font-sans)`,
      color: v.color,
      background: v.background,
      border: "var(--border-width) solid var(--m-outline)",
      borderRadius: "var(--radius-input)",
      cursor: disabled ? "default" : "pointer",
      opacity: disabled ? 0.6 : 1,
      filter: h && !disabled ? "brightness(1.1)" : "none",
      transition: "filter var(--duration-fast) var(--ease-standard)",
      whiteSpace: "nowrap",
      ...style
    }
  }, icon ? /*#__PURE__*/React.createElement(Icon, {
    name: icon,
    size: 15
  }) : null, children);
}

/* ---------- IconButton ---------- */
function IconButton({
  icon,
  size = 33,
  active,
  disabled,
  title,
  onClick,
  style = {}
}) {
  const [h, setH] = useState(false);
  const radius = Math.min(6, size / 2);
  const hovering = h && !disabled;
  let bg, fg, border;
  if (active) {
    bg = "var(--m-error)";
    fg = "var(--m-on-error)";
    border = "var(--m-error)";
  } else if (hovering) {
    bg = "var(--m-hover)";
    fg = "var(--m-on-hover)";
    border = "var(--m-outline)";
  } else {
    bg = "var(--m-surface-variant)";
    fg = "var(--m-primary)";
    border = "var(--m-outline)";
  }
  return /*#__PURE__*/React.createElement("button", {
    type: "button",
    title: title,
    disabled: disabled,
    onClick: onClick,
    onMouseEnter: () => setH(true),
    onMouseLeave: () => setH(false),
    style: {
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      width: size,
      height: size,
      padding: 0,
      background: bg,
      color: fg,
      border: `var(--border-width) solid ${border}`,
      borderRadius: radius,
      cursor: disabled ? "default" : "pointer",
      opacity: disabled ? 0.6 : 1,
      transition: "background var(--duration-fast) var(--ease-standard), color var(--duration-fast) var(--ease-standard)",
      ...style
    }
  }, /*#__PURE__*/React.createElement(Icon, {
    name: icon,
    size: Math.max(14, Math.round(size * 0.45))
  }));
}

/* ---------- Bubble ---------- */
const ACK = {
  pending: "🕓",
  sent: "✓",
  read: "✓✓",
  warn: "⚠"
};
function Bubble({
  from = "peer",
  text = "",
  time,
  ack,
  tps,
  quote,
  variant = "text",
  streaming,
  style = {}
}) {
  const mine = from === "me";
  if (variant === "notification") return /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      justifyContent: "center",
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      maxWidth: "85%",
      textAlign: "center",
      color: "var(--overlay-on-surface-45)",
      font: "var(--weight-medium) var(--text-s)/1.4 var(--font-sans)"
    }
  }, text));
  if (variant === "thinking") return /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      maxWidth: "85%",
      fontStyle: "italic",
      font: "italic var(--weight-medium) var(--text-s)/1.5 var(--font-sans)",
      color: "var(--overlay-on-surface-45)"
    }
  }, text || "thinking…"));
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      justifyContent: mine ? "flex-end" : "flex-start",
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      maxWidth: "85%",
      background: mine ? "var(--m-primary)" : "var(--m-surface-variant)",
      color: mine ? "var(--m-on-primary)" : "var(--m-on-surface)",
      border: mine ? "none" : "var(--border-width) solid var(--m-outline)",
      borderRadius: "var(--radius-s)",
      padding: "var(--space-m)",
      display: "flex",
      flexDirection: "column",
      gap: "var(--space-xxs)"
    }
  }, quote ? /*#__PURE__*/React.createElement("div", {
    style: {
      background: mine ? "var(--overlay-on-primary-15)" : "var(--overlay-on-surface-08)",
      color: mine ? "var(--overlay-on-primary-60)" : "var(--m-on-surface-variant)",
      borderRadius: "var(--radius-xs)",
      padding: "var(--space-xs) var(--space-s)",
      font: "var(--weight-medium) var(--text-xs)/1.4 var(--font-sans)",
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis"
    }
  }, "\u21B3 ", quote) : null, /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--weight-medium) var(--text-m)/1.5 var(--font-sans)",
      whiteSpace: "pre-wrap",
      wordBreak: "break-word"
    }
  }, text, streaming ? /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 2,
      opacity: 0.7
    }
  }, "\u258D") : null), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: "var(--space-xs)",
      justifyContent: mine ? "flex-end" : "flex-start"
    }
  }, time ? /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)",
      color: mine ? "var(--overlay-on-primary-60)" : "var(--m-on-surface-variant)"
    }
  }, time) : null, !mine && tps ? /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)",
      color: "var(--m-on-surface-variant)"
    }
  }, tps.toFixed(1), " t/s") : null, mine && ack ? /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--text-s)/1 var(--font-sans)",
      color: ack === "warn" ? "var(--m-error)" : "var(--overlay-on-primary-80)"
    }
  }, ACK[ack]) : null)));
}

/* ---------- ConfirmCard ---------- */
function ConfirmCard({
  title = "Run shell command?",
  command = "",
  state = "pending",
  machine,
  answeredBy,
  onAllow,
  onDeny,
  style = {}
}) {
  const bc = state === "allowed" ? "var(--m-tertiary)" : state === "denied" ? "var(--m-error)" : "var(--m-primary)";
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: "var(--m-surface-variant)",
      border: `var(--border-width) solid ${bc}`,
      borderRadius: "var(--radius-s)",
      padding: "var(--space-m)",
      display: "flex",
      flexDirection: "column",
      gap: "var(--space-s)",
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      justifyContent: "space-between",
      gap: "var(--space-s)"
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-bold) var(--text-m)/1.2 var(--font-sans)",
      color: "var(--m-on-surface)"
    }
  }, title), machine ? /*#__PURE__*/React.createElement(MachineChip, {
    name: machine.name,
    color: machine.color,
    size: "sm"
  }) : null), /*#__PURE__*/React.createElement("pre", {
    style: {
      margin: 0,
      background: "var(--m-surface)",
      border: "var(--border-width) solid var(--m-outline)",
      borderRadius: "var(--radius-xs)",
      padding: "var(--space-s) var(--space-m)",
      font: "var(--weight-medium) var(--text-s)/1.5 var(--font-mono)",
      color: "var(--m-on-surface)",
      whiteSpace: "pre-wrap",
      wordBreak: "break-all"
    }
  }, command), state === "pending" ? /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      justifyContent: "flex-end",
      gap: "var(--space-s)"
    }
  }, /*#__PURE__*/React.createElement(Button, {
    variant: "neutral",
    onClick: onDeny
  }, "Deny"), /*#__PURE__*/React.createElement(Button, {
    variant: "primary",
    onClick: onAllow
  }, "Allow")) : /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      justifyContent: "flex-end",
      alignItems: "center",
      gap: "var(--space-s)"
    }
  }, answeredBy ? /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)",
      color: "var(--m-on-surface-variant)"
    }
  }, answeredBy) : null, /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-bold) var(--text-s)/1 var(--font-sans)",
      color: state === "allowed" ? "var(--m-tertiary)" : "var(--m-error)"
    }
  }, state === "allowed" ? "✓ allowed" : "✗ denied")));
}

/* ---------- TextInput ---------- */
function TextInput({
  multiline,
  tone = "default",
  value,
  onChange,
  placeholder,
  rows = 1,
  style = {}
}) {
  const [focus, setFocus] = useState(false);
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
    font: "var(--weight-medium) var(--text-m)/1.4 var(--font-sans)",
    padding: "var(--space-s) var(--space-m)"
  };
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: bg,
      border: `var(--border-width) solid ${focus ? focusColor : "var(--m-outline)"}`,
      borderRadius: "var(--radius-input)",
      transition: "border-color var(--duration-fast) var(--ease-standard)",
      display: "flex",
      ...style
    }
  }, multiline ? /*#__PURE__*/React.createElement("textarea", {
    rows: rows,
    value: value,
    onChange: onChange,
    placeholder: placeholder,
    onFocus: () => setFocus(true),
    onBlur: () => setFocus(false),
    style: shared
  }) : /*#__PURE__*/React.createElement("input", {
    type: "text",
    value: value,
    onChange: onChange,
    placeholder: placeholder,
    onFocus: () => setFocus(true),
    onBlur: () => setFocus(false),
    style: shared
  }));
}

/* ---------- Divider ---------- */
function Divider({
  vertical,
  style = {}
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: "var(--m-outline)",
      flexShrink: 0,
      ...(vertical ? {
        width: "var(--border-width)",
        alignSelf: "stretch"
      } : {
        height: "var(--border-width)",
        width: "100%"
      }),
      ...style
    }
  });
}

/* ---------- shared machine catalogue (used by both kits) ---------- */
const MACHINES = {
  kiwi: {
    name: "kiwi",
    color: "var(--m-primary)",
    role: "desktop",
    status: "online",
    relayed: false,
    models: ["gemma3:27b", "qwen2.5-coder:14b", "llama3.2:3b"]
  },
  studio: {
    name: "studio",
    color: "var(--m-secondary)",
    role: "workstation",
    status: "offline",
    relayed: false,
    models: ["llama3.3:70b", "deepseek-r1:32b", "qwen2.5-coder:32b"]
  },
  nas: {
    name: "nas",
    color: "var(--m-tertiary)",
    role: "home server",
    status: "online",
    relayed: true,
    models: ["qwen2.5:7b", "phi4:14b"]
  }
};
window.SOS = {
  Icon,
  StatusDot,
  MachineChip,
  Button,
  IconButton,
  TextInput,
  Divider,
  Bubble,
  ConfirmCard,
  MACHINES
};

// keyframes once
if (!document.getElementById("sos-kf")) {
  const st = document.createElement("style");
  st.id = "sos-kf";
  st.textContent = "@keyframes sos-pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.45;transform:scale(.8)}}";
  document.head.appendChild(st);
}
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/pwa/kit.standalone.jsx", error: String((e && e.message) || e) }); }

// ui_kits/pwa/pwa.jsx
try { (() => {
// pi-chat PWA — phone client. Calmer redesign + reframed move UX.
//
// Move is NOT a buried "Move chat" wizard. A chat is a process on a
// machine, so "where it runs" is an editable property: the header's
// "running on kiwi" line IS the control. Tapping it opens "Where this
// runs" — one sheet unifying machine + model (+ memory on move). Same
// gesture as switching a model, because it's the same act.
const {
  useState,
  useEffect,
  useRef
} = React;
const {
  Icon,
  StatusDot,
  MachineChip,
  Button,
  IconButton,
  Bubble,
  ConfirmCard,
  MACHINES
} = window.SOS;
const SURFACE = "var(--m-surface)";
let _id = 200;
const uid = () => "m" + ++_id;
function seedChats() {
  return [{
    id: "c1",
    name: "Fix deploy.sh",
    machine: "kiwi",
    model: "qwen2.5-coder:14b",
    lifecycle: "idle",
    needsYou: true,
    unread: 0,
    time: "3m",
    preview: "Run shell command? sed -i …",
    messages: [{
      id: uid(),
      from: "me",
      text: "scan deploy.sh for footguns",
      time: "5m",
      ack: "read"
    }, {
      id: uid(),
      from: "peer",
      text: "Two issues: no `set -euo pipefail`, and the migration runs before the health check. Patch both?",
      time: "4m",
      tps: 47.9
    }, {
      id: uid(),
      from: "me",
      text: "yes, patch both",
      time: "3m",
      ack: "read",
      quote: "Patch both?"
    }, {
      id: "cc1",
      type: "confirm",
      command: "sed -i '1i set -euo pipefail' deploy.sh",
      confirmState: "pending"
    }]
  }, {
    id: "c2",
    name: "Groceries",
    machine: "kiwi",
    model: "llama3.2:3b",
    lifecycle: "working",
    needsYou: false,
    unread: 2,
    time: "10m",
    preview: "Sheet-pan harissa chicken?",
    messages: [{
      id: uid(),
      from: "me",
      text: "add oat milk + a tuesday dinner idea",
      time: "12m",
      ack: "read"
    }, {
      id: uid(),
      from: "peer",
      text: "Added oat milk. For Tuesday: sheet-pan harissa chicken?",
      time: "10m",
      tps: 61.0
    }]
  }, {
    id: "c3",
    name: "Summarize refs",
    machine: "studio",
    model: "llama3.3:70b",
    lifecycle: "idle",
    needsYou: false,
    unread: 0,
    time: "1h",
    preview: "Pushed a synthesis to notes/…",
    messages: [{
      id: uid(),
      from: "me",
      text: "summarize the three papers in ~/refs",
      time: "1h",
      ack: "sent"
    }, {
      id: uid(),
      from: "peer",
      text: "Pushed a synthesis to notes/synthesis.md.",
      time: "1h",
      tps: 18.4
    }]
  }, {
    id: "c4",
    name: "Berlin trip",
    machine: "nas",
    model: "qwen2.5:7b",
    lifecycle: "idle",
    needsYou: false,
    unread: 0,
    time: "2h",
    preview: "Booked the 9:40 train.",
    messages: [{
      id: uid(),
      from: "me",
      text: "book the cheapest morning train to berlin",
      time: "2h",
      ack: "read"
    }, {
      id: uid(),
      from: "peer",
      text: "Booked the 9:40 train — confirmation in your mail.",
      time: "2h",
      tps: 39.2
    }]
  }];
}
function chatState(c) {
  if (MACHINES[c.machine].status === "offline") return "unreachable";
  if (c.needsYou) return "needs-you";
  if (c.lifecycle === "working") return "working";
  return "idle";
}

/* ============================ root ============================ */
function App() {
  const [chats, setChats] = useState(seedChats);
  const [view, setView] = useState({
    name: "chats"
  });
  const [sheet, setSheet] = useState(null); // {type:'runon'|'where', chatId?}
  function patch(id, fn) {
    setChats(cs => cs.map(c => c.id === id ? fn(c) : c));
  }
  return /*#__PURE__*/React.createElement(IOSDevice, {
    dark: true
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      height: "100%",
      position: "relative",
      overflow: "hidden",
      background: SURFACE,
      display: "flex",
      flexDirection: "column"
    }
  }, view.name === "chats" && /*#__PURE__*/React.createElement(ChatList, {
    chats: chats,
    onOpen: id => setView({
      name: "chat",
      chatId: id
    }),
    onNew: () => setSheet({
      type: "runon"
    })
  }), view.name === "machines" && /*#__PURE__*/React.createElement(Machines, {
    chats: chats
  }), view.name === "chat" && /*#__PURE__*/React.createElement(ChatView, {
    chat: chats.find(c => c.id === view.chatId),
    patch: patch,
    onBack: () => setView({
      name: "chats"
    }),
    onRuntime: id => setSheet({
      type: "where",
      chatId: id
    })
  }), view.name !== "chat" && /*#__PURE__*/React.createElement(TabBar, {
    view: view.name,
    setView: setView
  }), sheet?.type === "runon" && /*#__PURE__*/React.createElement(RunOnSheet, {
    onClose: () => setSheet(null),
    onPick: mk => {
      const id = "c" + Date.now();
      const m = MACHINES[mk];
      setChats(cs => [{
        id,
        name: "New chat",
        machine: mk,
        model: m.models[0],
        lifecycle: "idle",
        needsYou: false,
        unread: 0,
        time: "now",
        preview: "—",
        messages: [{
          id: uid(),
          type: "notification",
          text: m.name + " · new session · " + m.models[0]
        }]
      }, ...cs]);
      setSheet(null);
      setView({
        name: "chat",
        chatId: id
      });
    }
  }), sheet?.type === "where" && /*#__PURE__*/React.createElement(WhereSheet, {
    chat: chats.find(c => c.id === sheet.chatId),
    onClose: () => setSheet(null),
    onMove: tk => {
      const c = chats.find(x => x.id === sheet.chatId);
      const t = MACHINES[tk];
      const nm = t.models.includes(c.model) ? c.model : t.models[0];
      patch(c.id, s => ({
        ...s,
        machine: tk,
        model: nm,
        messages: [...s.messages, {
          id: uid(),
          type: "notification",
          text: "now running on " + t.name + " · " + nm
        }]
      }));
    },
    onModel: model => patch(sheet.chatId, s => ({
      ...s,
      model
    }))
  })));
}

/* ============================ chat list (calm) ============================ */
function ChatList({
  chats,
  onOpen,
  onNew
}) {
  return /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("div", {
    style: {
      paddingTop: 56,
      paddingLeft: 20,
      paddingRight: 14,
      paddingBottom: 8,
      display: "flex",
      alignItems: "center"
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      font: "var(--weight-bold) var(--text-3xl)/1 var(--font-sans)",
      color: "var(--m-on-surface)",
      letterSpacing: "var(--tracking-tight)"
    }
  }, "Chats"), /*#__PURE__*/React.createElement(IconButton, {
    icon: "plus",
    size: 38,
    title: "New chat",
    onClick: onNew
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      overflowY: "auto",
      padding: "4px 12px 96px",
      display: "flex",
      flexDirection: "column"
    }
  }, chats.map((c, i) => /*#__PURE__*/React.createElement(ChatRow, {
    key: c.id,
    c: c,
    last: i === chats.length - 1,
    onOpen: () => onOpen(c.id)
  }))));
}
function ChatRow({
  c,
  last,
  onOpen
}) {
  const m = MACHINES[c.machine];
  const state = chatState(c);
  const unreachable = state === "unreachable";
  const badge = /*#__PURE__*/React.createElement(ChatBadge, {
    state: state,
    unread: c.unread
  });
  return /*#__PURE__*/React.createElement("button", {
    onClick: onOpen,
    style: {
      width: "100%",
      textAlign: "left",
      display: "flex",
      gap: 12,
      alignItems: "stretch",
      padding: "13px 8px",
      background: "none",
      border: "none",
      borderBottom: last ? "none" : "var(--border-width) solid var(--m-outline)",
      cursor: "pointer",
      opacity: unreachable ? 0.55 : 1
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      width: 3,
      alignSelf: "stretch",
      borderRadius: 2,
      background: m.color,
      flexShrink: 0
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      minWidth: 0
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "baseline",
      gap: 8
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1,
      font: "var(--weight-bold) var(--text-m)/1.2 var(--font-sans)",
      color: "var(--m-on-surface)",
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis"
    }
  }, c.name), /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)",
      color: m.color,
      flexShrink: 0
    }
  }, m.name), /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)",
      color: "var(--m-on-surface-variant)",
      flexShrink: 0
    }
  }, c.time)), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: 8,
      marginTop: 5
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1,
      font: "var(--weight-medium) var(--text-s)/1.3 var(--font-sans)",
      color: "var(--m-on-surface-variant)",
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis"
    }
  }, c.preview), badge)));
}
function ChatBadge({
  state,
  unread
}) {
  if (state === "needs-you") return /*#__PURE__*/React.createElement("span", {
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: 5,
      height: 19,
      padding: "0 8px",
      borderRadius: "var(--radius-xs)",
      background: "var(--m-primary)",
      color: "var(--m-on-primary)",
      font: "var(--weight-bold) var(--text-xs)/1 var(--font-sans)",
      flexShrink: 0
    }
  }, /*#__PURE__*/React.createElement(Icon, {
    name: "key",
    size: 11
  }), "needs you");
  if (state === "working") return /*#__PURE__*/React.createElement("span", {
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: 5,
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)",
      color: "var(--m-primary)",
      flexShrink: 0
    }
  }, /*#__PURE__*/React.createElement(StatusDot, {
    status: "working",
    size: 7
  }), "working");
  if (state === "unreachable") return /*#__PURE__*/React.createElement("span", {
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: 4,
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)",
      color: "var(--m-on-surface-variant)",
      flexShrink: 0
    }
  }, /*#__PURE__*/React.createElement(Icon, {
    name: "database-off",
    size: 12
  }), "offline");
  if (unread > 0) return /*#__PURE__*/React.createElement("span", {
    style: {
      minWidth: 18,
      height: 18,
      padding: "0 5px",
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      borderRadius: "var(--radius-xs)",
      background: "var(--m-primary)",
      color: "var(--m-on-primary)",
      font: "var(--weight-bold) var(--text-xs)/1 var(--font-sans)",
      flexShrink: 0
    }
  }, unread);
  return null;
}

/* ============================ chat view ============================ */
function ChatView({
  chat,
  patch,
  onBack,
  onRuntime
}) {
  const [draft, setDraft] = useState("");
  const listRef = useRef(null);
  const m = MACHINES[chat.machine];
  const reachable = m.status !== "offline";
  useEffect(() => {
    if (listRef.current) listRef.current.scrollTop = listRef.current.scrollHeight;
  }, [chat.messages.length]);
  function send() {
    if (!draft.trim() || !reachable) return;
    const text = draft.trim();
    patch(chat.id, c => ({
      ...c,
      needsYou: false,
      messages: [...c.messages, {
        id: uid(),
        from: "me",
        text,
        time: "now",
        ack: "sent"
      }]
    }));
    setDraft("");
    setTimeout(() => patch(chat.id, c => ({
      ...c,
      messages: [...c.messages, {
        id: uid(),
        from: "peer",
        text: "Got it — continuing on " + c.machine + ".",
        time: "now",
        tps: 45.0
      }]
    })), 900);
  }
  function answer(id, ok) {
    patch(chat.id, c => ({
      ...c,
      needsYou: false,
      messages: c.messages.map(x => x.id === id ? {
        ...x,
        confirmState: ok ? "allowed" : "denied"
      } : x)
    }));
  }
  return /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("div", {
    style: {
      paddingTop: 50,
      padding: "50px 10px 0",
      display: "flex",
      alignItems: "center",
      gap: 6
    }
  }, /*#__PURE__*/React.createElement(IconButton, {
    icon: "chevron-up",
    size: 34,
    title: "Back",
    onClick: onBack,
    style: {
      transform: "rotate(-90deg)"
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1,
      minWidth: 0,
      font: "var(--weight-bold) var(--text-l)/1.15 var(--font-sans)",
      color: "var(--m-on-surface)",
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis"
    }
  }, chat.name)), /*#__PURE__*/React.createElement("button", {
    onClick: () => onRuntime(chat.id),
    style: {
      display: "flex",
      alignItems: "center",
      gap: 7,
      margin: "6px 12px 0",
      padding: "8px 12px",
      width: "calc(100% - 24px)",
      background: "var(--m-surface-variant)",
      border: "var(--border-width) solid var(--m-outline)",
      borderRadius: "var(--radius-input)",
      cursor: "pointer"
    }
  }, /*#__PURE__*/React.createElement(StatusDot, {
    status: reachable ? "online" : "offline",
    size: 8
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-bold) var(--text-s)/1 var(--font-mono)",
      color: m.color,
      flexShrink: 0
    }
  }, m.name), /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)",
      color: "var(--m-on-surface-variant)",
      overflow: "hidden",
      textOverflow: "ellipsis",
      whiteSpace: "nowrap"
    }
  }, "\xB7 ", chat.model), /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)",
      color: "var(--m-secondary)",
      whiteSpace: "nowrap",
      flexShrink: 0
    }
  }, "Where it runs"), /*#__PURE__*/React.createElement(Icon, {
    name: "chevron-down",
    size: 14,
    color: "var(--m-secondary)"
  })), /*#__PURE__*/React.createElement("div", {
    ref: listRef,
    style: {
      flex: 1,
      overflowY: "auto",
      display: "flex",
      flexDirection: "column",
      gap: "var(--space-m)",
      padding: "var(--space-m)"
    }
  }, chat.messages.map(x => x.type === "confirm" ? /*#__PURE__*/React.createElement(ConfirmCard, {
    key: x.id,
    command: x.command,
    state: x.confirmState,
    machine: {
      name: m.name,
      color: m.color
    },
    onAllow: () => answer(x.id, true),
    onDeny: () => answer(x.id, false)
  }) : /*#__PURE__*/React.createElement(Bubble, {
    key: x.id,
    from: x.from,
    text: x.text,
    time: x.time,
    ack: x.ack,
    tps: x.tps,
    quote: x.quote,
    variant: x.type === "notification" ? "notification" : x.type === "thinking" ? "thinking" : "text"
  }))), !reachable ? /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: 8,
      margin: "0 12px 26px",
      padding: "var(--space-m)",
      background: "var(--m-surface-variant)",
      border: "var(--border-width) solid var(--m-error)",
      borderRadius: "var(--radius-s)"
    }
  }, /*#__PURE__*/React.createElement(Icon, {
    name: "database-off",
    size: 16,
    color: "var(--m-error)"
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-s)/1.4 var(--font-sans)",
      color: "var(--m-on-surface)"
    }
  }, "Can\u2019t reach ", /*#__PURE__*/React.createElement("b", {
    style: {
      fontFamily: "var(--font-mono)",
      color: m.color
    }
  }, m.name), " \u2014 cached, read-only.")) : /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "flex-end",
      gap: 8,
      padding: "10px 12px 26px"
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      display: "flex",
      background: "var(--m-surface-variant)",
      border: "var(--border-width) solid var(--m-outline)",
      borderRadius: "var(--radius-input)"
    }
  }, /*#__PURE__*/React.createElement("input", {
    value: draft,
    onChange: e => setDraft(e.target.value),
    onKeyDown: e => {
      if (e.key === "Enter") {
        e.preventDefault();
        send();
      }
    },
    placeholder: "Message " + m.name + "…",
    style: {
      width: "100%",
      background: "transparent",
      border: "none",
      outline: "none",
      color: "var(--m-on-surface)",
      font: "var(--weight-medium) var(--text-m)/1.2 var(--font-sans)",
      padding: "10px 14px"
    }
  })), /*#__PURE__*/React.createElement(IconButton, {
    icon: "microphone",
    size: 42,
    title: "Voice"
  }), /*#__PURE__*/React.createElement(IconButton, {
    icon: "send",
    size: 42,
    title: "Send",
    disabled: !draft.trim(),
    onClick: send
  })));
}

/* ============================ machines roster ============================ */
function Machines({
  chats
}) {
  return /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("div", {
    style: {
      paddingTop: 56,
      paddingLeft: 20,
      paddingRight: 16,
      paddingBottom: 10
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--weight-bold) var(--text-3xl)/1 var(--font-sans)",
      color: "var(--m-on-surface)",
      letterSpacing: "var(--tracking-tight)"
    }
  }, "Machines"), /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--weight-medium) var(--text-s)/1.3 var(--font-sans)",
      color: "var(--m-on-surface-variant)",
      marginTop: 4
    }
  }, "Where your agents actually run")), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      overflowY: "auto",
      padding: "4px 16px 96px",
      display: "flex",
      flexDirection: "column",
      gap: "var(--space-m)"
    }
  }, Object.values(MACHINES).map(m => {
    const count = chats.filter(c => c.machine === m.name).length;
    const off = m.status === "offline";
    return /*#__PURE__*/React.createElement("div", {
      key: m.name,
      style: {
        background: "var(--m-surface-variant)",
        border: "var(--border-width) solid " + (off ? "var(--m-outline)" : m.color),
        borderRadius: "var(--radius-s)",
        padding: "var(--space-m)",
        opacity: off ? 0.7 : 1
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        alignItems: "center",
        gap: 10,
        whiteSpace: "nowrap"
      }
    }, /*#__PURE__*/React.createElement(StatusDot, {
      status: m.status,
      size: 12
    }), /*#__PURE__*/React.createElement("span", {
      style: {
        font: "var(--weight-bold) var(--text-xl)/1 var(--font-mono)",
        color: m.color,
        flexShrink: 0
      }
    }, m.name), /*#__PURE__*/React.createElement("span", {
      style: {
        font: "var(--weight-medium) var(--text-s)/1 var(--font-sans)",
        color: "var(--m-on-surface-variant)",
        overflow: "hidden",
        textOverflow: "ellipsis",
        minWidth: 0
      }
    }, m.role), /*#__PURE__*/React.createElement("span", {
      style: {
        flex: 1
      }
    }), /*#__PURE__*/React.createElement("span", {
      style: {
        font: "var(--weight-semibold) var(--text-xs)/1 var(--font-sans)",
        color: off ? "var(--m-error)" : "var(--m-tertiary)",
        flexShrink: 0
      }
    }, off ? "offline" : m.relayed ? "online · relayed" : "online · direct")), /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        gap: 18,
        marginTop: 12
      }
    }, /*#__PURE__*/React.createElement(Stat, {
      label: "chats",
      value: count
    }), /*#__PURE__*/React.createElement(Stat, {
      label: "models",
      value: m.models.length
    }), /*#__PURE__*/React.createElement(Stat, {
      label: "default",
      value: m.name === "kiwi" ? "yes" : "—"
    })), /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        flexWrap: "wrap",
        gap: 6,
        marginTop: 12
      }
    }, m.models.map(mod => /*#__PURE__*/React.createElement("span", {
      key: mod,
      style: {
        font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)",
        color: "var(--m-on-surface)",
        background: "var(--m-surface)",
        border: "var(--border-width) solid var(--m-outline)",
        borderRadius: "var(--radius-xs)",
        padding: "5px 8px"
      }
    }, mod))));
  })));
}
function Stat({
  label,
  value
}) {
  return /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--weight-bold) var(--text-l)/1 var(--font-sans)",
      color: "var(--m-on-surface)"
    }
  }, value), /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)",
      color: "var(--m-on-surface-variant)",
      marginTop: 3
    }
  }, label));
}

/* ============================ tab bar ============================ */
function TabBar({
  view,
  setView
}) {
  const tab = (name, icon, label) => {
    const on = view === name;
    return /*#__PURE__*/React.createElement("button", {
      onClick: () => setView({
        name
      }),
      style: {
        flex: 1,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        gap: 3,
        background: "none",
        border: "none",
        cursor: "pointer",
        padding: "8px 0"
      }
    }, /*#__PURE__*/React.createElement(Icon, {
      name: icon,
      size: 22,
      color: on ? "var(--m-primary)" : "var(--m-on-surface-variant)"
    }), /*#__PURE__*/React.createElement("span", {
      style: {
        font: (on ? "var(--weight-semibold)" : "var(--weight-medium)") + " var(--text-xs)/1 var(--font-sans)",
        color: on ? "var(--m-primary)" : "var(--m-on-surface-variant)"
      }
    }, label));
  };
  return /*#__PURE__*/React.createElement("div", {
    style: {
      position: "absolute",
      left: 0,
      right: 0,
      bottom: 0,
      paddingBottom: 22,
      display: "flex",
      background: "rgba(7,7,34,0.82)",
      backdropFilter: "blur(12px)",
      borderTop: "var(--border-width) solid var(--m-outline)",
      zIndex: 8
    }
  }, tab("chats", "message-chatbot", "Chats"), tab("machines", "gauge", "Machines"));
}

/* ============================ bottom sheets ============================ */
function BottomSheet({
  onClose,
  children
}) {
  return /*#__PURE__*/React.createElement("div", {
    onClick: onClose,
    style: {
      position: "absolute",
      inset: 0,
      background: "rgba(4,4,15,0.7)",
      backdropFilter: "blur(3px)",
      display: "flex",
      alignItems: "flex-end",
      zIndex: 40
    }
  }, /*#__PURE__*/React.createElement("div", {
    onClick: e => e.stopPropagation(),
    style: {
      width: "100%",
      background: SURFACE,
      borderTopLeftRadius: 12,
      borderTopRightRadius: 12,
      border: "var(--border-width) solid var(--m-outline)",
      borderBottom: "none",
      paddingBottom: 30,
      maxHeight: "84%",
      overflowY: "auto"
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      width: 38,
      height: 4,
      borderRadius: 2,
      background: "var(--m-outline)",
      margin: "10px auto 4px"
    }
  }), children));
}
function SheetHead({
  title,
  sub
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      padding: "10px 18px 14px"
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-bold) var(--text-xl)/1.15 var(--font-sans)",
      color: "var(--m-on-surface)"
    }
  }, title), sub ? /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--weight-medium) var(--text-s)/1.45 var(--font-sans)",
      color: "var(--m-on-surface-variant)",
      marginTop: 6
    }
  }, sub) : null);
}
function RunOnSheet({
  onClose,
  onPick
}) {
  return /*#__PURE__*/React.createElement(BottomSheet, {
    onClose: onClose
  }, /*#__PURE__*/React.createElement(SheetHead, {
    title: "Start a chat",
    sub: "Pick the machine that will run the agent."
  }), Object.values(MACHINES).map(m => {
    const off = m.status === "offline";
    return /*#__PURE__*/React.createElement("div", {
      key: m.name,
      onClick: off ? undefined : () => onPick(m.name),
      style: {
        display: "flex",
        alignItems: "center",
        gap: 12,
        padding: "13px 18px",
        borderTop: "var(--border-width) solid var(--m-outline)",
        cursor: off ? "default" : "pointer",
        opacity: off ? 0.5 : 1
      }
    }, /*#__PURE__*/React.createElement(StatusDot, {
      status: m.status,
      size: 11
    }), /*#__PURE__*/React.createElement("div", {
      style: {
        flex: 1,
        minWidth: 0
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        alignItems: "center",
        gap: 8,
        whiteSpace: "nowrap"
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        font: "var(--weight-bold) var(--text-m)/1 var(--font-mono)",
        color: m.color
      }
    }, m.name), /*#__PURE__*/React.createElement("span", {
      style: {
        font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)",
        color: "var(--m-on-surface-variant)"
      }
    }, m.role)), /*#__PURE__*/React.createElement("div", {
      style: {
        font: "var(--weight-medium) var(--text-xs)/1.4 var(--font-mono)",
        color: off ? "var(--m-error)" : "var(--m-on-surface-variant)",
        marginTop: 4,
        whiteSpace: "nowrap",
        overflow: "hidden",
        textOverflow: "ellipsis"
      }
    }, off ? "unreachable" : m.models.join(" · "))), !off ? /*#__PURE__*/React.createElement(Icon, {
      name: "chevron-up",
      size: 16,
      color: "var(--m-on-surface-variant)",
      style: {
        transform: "rotate(90deg)"
      }
    }) : null);
  }));
}

/* "Where this runs" — the reframed move: machine + model in one place. */
function WhereSheet({
  chat,
  onClose,
  onMove,
  onModel
}) {
  const [mem, setMem] = useState(false);
  const cur = MACHINES[chat.machine];
  const sourceReachable = cur.status !== "offline";
  return /*#__PURE__*/React.createElement(BottomSheet, {
    onClose: onClose
  }, /*#__PURE__*/React.createElement(SheetHead, {
    title: "Where this runs",
    sub: "This chat is a process on a machine. Point it at whichever machine should run it \u2014 same chat, new home."
  }), !sourceReachable ? /*#__PURE__*/React.createElement("div", {
    style: {
      margin: "0 18px 10px",
      padding: "var(--space-s) var(--space-m)",
      background: "var(--m-surface-variant)",
      border: "var(--border-width) solid var(--m-error)",
      borderRadius: "var(--radius-s)",
      font: "var(--weight-medium) var(--text-xs)/1.4 var(--font-sans)",
      color: "var(--m-on-surface)"
    }
  }, /*#__PURE__*/React.createElement("b", {
    style: {
      fontFamily: "var(--font-mono)",
      color: cur.color
    }
  }, cur.name), " is offline \u2014 reconnect to it before moving this chat.") : null, /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)",
      color: "var(--m-on-surface-variant)",
      textTransform: "uppercase",
      letterSpacing: "var(--tracking-wide)",
      padding: "2px 18px 6px"
    }
  }, "machine"), Object.values(MACHINES).map(m => {
    const current = m.name === chat.machine;
    const off = m.status === "offline";
    const disabled = off || !current && !sourceReachable;
    const keeps = m.models.includes(chat.model);
    const hint = current ? "current home" : off ? "unreachable" : keeps ? "keeps " + chat.model : chat.model + " → " + m.models[0];
    return /*#__PURE__*/React.createElement("div", {
      key: m.name,
      onClick: disabled || current ? undefined : () => onMove(m.name),
      style: {
        display: "flex",
        alignItems: "center",
        gap: 12,
        padding: "12px 18px",
        borderTop: "var(--border-width) solid var(--m-outline)",
        cursor: disabled || current ? "default" : "pointer",
        opacity: disabled ? 0.5 : 1,
        background: current ? "var(--m-surface-variant)" : "transparent"
      }
    }, /*#__PURE__*/React.createElement(StatusDot, {
      status: m.status,
      size: 11
    }), /*#__PURE__*/React.createElement("div", {
      style: {
        flex: 1,
        minWidth: 0
      }
    }, /*#__PURE__*/React.createElement("div", {
      style: {
        display: "flex",
        alignItems: "center",
        gap: 8,
        whiteSpace: "nowrap"
      }
    }, /*#__PURE__*/React.createElement("span", {
      style: {
        font: "var(--weight-bold) var(--text-m)/1 var(--font-mono)",
        color: m.color
      }
    }, m.name), /*#__PURE__*/React.createElement("span", {
      style: {
        font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)",
        color: "var(--m-on-surface-variant)"
      }
    }, m.role)), /*#__PURE__*/React.createElement("div", {
      style: {
        font: "var(--weight-medium) var(--text-xs)/1.3 var(--font-mono)",
        color: off ? "var(--m-error)" : "var(--m-on-surface-variant)",
        marginTop: 3
      }
    }, hint)), current ? /*#__PURE__*/React.createElement(Icon, {
      name: "check",
      size: 16,
      color: "var(--m-primary)"
    }) : !disabled ? /*#__PURE__*/React.createElement("span", {
      style: {
        font: "var(--weight-semibold) var(--text-xs)/1 var(--font-sans)",
        color: "var(--m-secondary)"
      }
    }, "move") : null);
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)",
      color: "var(--m-on-surface-variant)",
      textTransform: "uppercase",
      letterSpacing: "var(--tracking-wide)",
      padding: "16px 18px 8px",
      borderTop: "var(--border-width) solid var(--m-outline)"
    }
  }, "model on ", cur.name), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      flexWrap: "wrap",
      gap: 7,
      padding: "0 18px 8px"
    }
  }, cur.models.map(mod => {
    const on = mod === chat.model;
    return /*#__PURE__*/React.createElement("button", {
      key: mod,
      onClick: () => onModel(mod),
      style: {
        display: "inline-flex",
        alignItems: "center",
        gap: 6,
        height: 30,
        padding: "0 12px",
        borderRadius: "var(--radius-input)",
        cursor: "pointer",
        background: on ? "var(--m-primary)" : "var(--m-surface-variant)",
        border: "var(--border-width) solid " + (on ? "transparent" : "var(--m-outline)"),
        color: on ? "var(--m-on-primary)" : "var(--m-on-surface)",
        font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)"
      }
    }, on ? /*#__PURE__*/React.createElement(Icon, {
      name: "check",
      size: 12
    }) : null, mod);
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: 10,
      padding: "12px 18px 4px",
      borderTop: "var(--border-width) solid var(--m-outline)",
      marginTop: 8
    }
  }, /*#__PURE__*/React.createElement("button", {
    onClick: () => setMem(v => !v),
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: 9,
      background: "none",
      border: "none",
      cursor: "pointer",
      padding: 0
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      width: 20,
      height: 20,
      borderRadius: 4,
      border: "var(--border-width) solid var(--m-outline)",
      background: mem ? "var(--m-primary)" : "transparent",
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center"
    }
  }, mem ? /*#__PURE__*/React.createElement(Icon, {
    name: "check",
    size: 14,
    color: "var(--m-on-primary)"
  }) : null), /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-s)/1.3 var(--font-sans)",
      color: "var(--m-on-surface)",
      whiteSpace: "nowrap"
    }
  }, "Bring memory when moving")), /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1.3 var(--font-sans)",
      color: "var(--m-on-surface-variant)"
    }
  }, mem ? "copies sediment" : "stays on " + cur.name)));
}
ReactDOM.createRoot(document.getElementById("root")).render(/*#__PURE__*/React.createElement(App, null));
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/pwa/pwa.jsx", error: String((e && e.message) || e) }); }

// ui_kits/quickshell-panel/panel.jsx
try { (() => {
// pi-chat Quickshell sidepanel — calmer, machine-aware redesign.
// Key changes from the noctalia first-draft:
//   · no always-on horizontal tab strip (doesn't scale) — chats live in a
//     scrollable drawer opened from a single title switcher
//   · the chat name appears ONCE (the header title), not in a tab too
//   · the 5 header icons collapse into one overflow menu
//   · sharper corners throughout
const {
  useState,
  useEffect,
  useRef
} = React;
const {
  Icon,
  StatusDot,
  MachineChip,
  Button,
  IconButton,
  Bubble,
  ConfirmCard,
  MACHINES
} = window.SOS;
const PANEL_W = 480;
let _id = 100;
const uid = () => "m" + ++_id;
function seedSessions() {
  return [{
    id: "s1",
    name: "Fix deploy.sh",
    machine: "kiwi",
    model: "qwen2.5-coder:14b",
    lifecycle: "idle",
    needsYou: true,
    unread: 0,
    time: "3m",
    preview: "Run shell command? sed -i …",
    messages: [{
      id: uid(),
      from: "me",
      text: "scan deploy.sh for footguns",
      time: "4m",
      ack: "read"
    }, {
      id: uid(),
      from: "peer",
      type: "thinking",
      text: "Checking error handling and the migration / health-check ordering…"
    }, {
      id: uid(),
      from: "peer",
      text: "Two issues:\n1. no `set -euo pipefail`\n2. the migration runs *before* the health check.\n\nPatch both?",
      time: "3m",
      tps: 47.9
    }, {
      id: uid(),
      from: "me",
      text: "yes, patch both",
      time: "2m",
      ack: "read",
      quote: "Patch both?"
    }, {
      id: "confirm1",
      type: "confirm",
      command: "sed -i '1i set -euo pipefail' deploy.sh",
      confirmState: "pending"
    }]
  }, {
    id: "s2",
    name: "Groceries",
    machine: "kiwi",
    model: "llama3.2:3b",
    lifecycle: "working",
    needsYou: false,
    unread: 2,
    time: "10m",
    preview: "Sheet-pan harissa chicken?",
    messages: [{
      id: uid(),
      from: "me",
      text: "add oat milk + a tuesday dinner idea",
      time: "12m",
      ack: "read"
    }, {
      id: uid(),
      from: "peer",
      text: "Added oat milk. For Tuesday: sheet-pan harissa chicken?",
      time: "10m",
      tps: 61.0
    }]
  }, {
    id: "s3",
    name: "Summarize refs",
    machine: "studio",
    model: "llama3.3:70b",
    lifecycle: "idle",
    needsYou: false,
    unread: 0,
    time: "1h",
    preview: "Pushed a synthesis to notes/…",
    messages: [{
      id: uid(),
      from: "me",
      text: "summarize the three papers in ~/refs",
      time: "1h",
      ack: "sent"
    }, {
      id: uid(),
      from: "peer",
      text: "Pushed a synthesis to notes/synthesis.md.",
      time: "1h",
      tps: 18.4
    }]
  }, {
    id: "s4",
    name: "Berlin trip",
    machine: "nas",
    model: "qwen2.5:7b",
    lifecycle: "idle",
    needsYou: false,
    unread: 0,
    time: "2h",
    preview: "Booked the 9:40 train.",
    messages: [{
      id: uid(),
      from: "me",
      text: "book the cheapest morning train to berlin",
      time: "2h",
      ack: "read"
    }, {
      id: uid(),
      from: "peer",
      text: "Booked the 9:40 train — confirmation in your mail.",
      time: "2h",
      tps: 39.2
    }]
  }];
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
  function patch(id, fn) {
    setSessions(ss => ss.map(s => s.id === id ? fn(s) : s));
  }
  return /*#__PURE__*/React.createElement("div", {
    style: {
      position: "relative",
      width: "100vw",
      height: "100vh",
      overflow: "hidden"
    }
  }, /*#__PURE__*/React.createElement(TopBar, null), /*#__PURE__*/React.createElement(DesktopHint, null), /*#__PURE__*/React.createElement("div", {
    style: {
      position: "absolute",
      top: 36,
      right: 0,
      bottom: 0,
      width: PANEL_W,
      background: "var(--m-surface)",
      borderLeft: "var(--border-width) solid var(--m-outline)",
      borderTopLeftRadius: "var(--radius-s)",
      boxShadow: "var(--shadow-overlay)",
      display: "flex"
    }
  }, /*#__PURE__*/React.createElement(Panel, {
    sessions: sessions,
    setSessions: setSessions,
    activeId: activeId,
    setActiveId: setActiveId,
    active: active,
    patch: patch
  })));
}
function TopBar() {
  const [clock, setClock] = useState("");
  useEffect(() => {
    const t = () => setClock(new Date().toLocaleTimeString([], {
      hour: "2-digit",
      minute: "2-digit"
    }));
    t();
    const i = setInterval(t, 10000);
    return () => clearInterval(i);
  }, []);
  return /*#__PURE__*/React.createElement("div", {
    style: {
      position: "absolute",
      top: 0,
      left: 0,
      right: 0,
      height: 36,
      display: "flex",
      alignItems: "center",
      padding: "0 14px",
      gap: 12,
      background: "rgba(7,7,34,0.72)",
      backdropFilter: "blur(8px)",
      borderBottom: "var(--border-width) solid var(--m-outline)",
      zIndex: 5
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      gap: 6
    }
  }, [1, 2, 3].map(n => /*#__PURE__*/React.createElement("span", {
    key: n,
    style: {
      width: 7,
      height: 7,
      borderRadius: 2,
      background: n === 1 ? "var(--m-primary)" : "var(--m-outline)"
    }
  }))), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)",
      color: "var(--m-on-surface-variant)",
      marginRight: 2
    }
  }, "machines"), Object.values(MACHINES).map(m => /*#__PURE__*/React.createElement(MachineChip, {
    key: m.name,
    name: m.name,
    color: m.color,
    status: m.status,
    relayed: m.relayed,
    size: "sm"
  })), /*#__PURE__*/React.createElement("span", {
    style: {
      width: 1,
      height: 16,
      background: "var(--m-outline)",
      margin: "0 4px"
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-s)/1 var(--font-mono)",
      color: "var(--m-on-surface)"
    }
  }, clock));
}
function DesktopHint() {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      position: "absolute",
      left: 40,
      bottom: 34,
      color: "var(--m-on-surface-variant)",
      maxWidth: 360
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--weight-semibold) var(--text-l)/1.3 var(--font-sans)",
      color: "var(--m-on-surface)",
      opacity: 0.5
    }
  }, "Spaces OS"), /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--weight-medium) var(--text-s)/1.5 var(--font-sans)",
      opacity: 0.45,
      marginTop: 4
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: "var(--font-mono)",
      color: "var(--m-primary)"
    }
  }, "Mod\xA0+\xA0A"), " agent panel \xB7 ", /*#__PURE__*/React.createElement("span", {
    style: {
      fontFamily: "var(--font-mono)",
      color: "var(--m-primary)"
    }
  }, "Mod\xA0+\xA0/"), " background task"));
}

/* ============================ the panel ============================ */
function Panel({
  sessions,
  setSessions,
  activeId,
  setActiveId,
  active,
  patch
}) {
  const [draft, setDraft] = useState("");
  const [drawer, setDrawer] = useState(false); // chat list
  const [runOn, setRunOn] = useState(false); // new-chat picker
  const [whereFor, setWhereFor] = useState(null); // "where this runs" (machine + model)
  const [overflow, setOverflow] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const listRef = useRef(null);
  const machine = MACHINES[active.machine];
  const reachable = machine.status !== "offline";
  useEffect(() => {
    if (listRef.current) listRef.current.scrollTop = listRef.current.scrollHeight;
  }, [active.messages.length, activeId]);
  function send() {
    if (!draft.trim() || !reachable) return;
    const text = draft.trim();
    patch(active.id, s => ({
      ...s,
      messages: [...s.messages, {
        id: uid(),
        from: "me",
        text,
        time: "now",
        ack: "sent"
      }]
    }));
    setDraft("");
    setTimeout(() => patch(active.id, s => ({
      ...s,
      messages: [...s.messages, {
        id: uid(),
        from: "peer",
        text: "On it — running on " + s.machine + ".",
        time: "now",
        tps: 44.0
      }]
    })), 1000);
  }
  function answerConfirm(id, ok) {
    patch(active.id, s => ({
      ...s,
      needsYou: false,
      messages: s.messages.map(m => m.id === id ? {
        ...m,
        confirmState: ok ? "allowed" : "denied"
      } : m)
    }));
  }
  function startChat(mk) {
    const m = MACHINES[mk];
    const id = "s" + Date.now();
    setSessions(ss => [...ss, {
      id,
      name: "New chat",
      machine: mk,
      model: m.models[0],
      lifecycle: "idle",
      needsYou: false,
      unread: 0,
      time: "now",
      preview: "—",
      messages: [{
        id: uid(),
        type: "notification",
        text: m.name + " · new session · " + m.models[0]
      }]
    }]);
    setActiveId(id);
    setRunOn(false);
    setDrawer(false);
  }
  function doMove(tk) {
    const sess = whereFor,
      t = MACHINES[tk],
      nm = t.models.includes(sess.model) ? sess.model : t.models[0];
    patch(sess.id, s => ({
      ...s,
      machine: tk,
      model: nm,
      messages: [...s.messages, {
        id: uid(),
        type: "notification",
        text: "now running on " + t.name + " · " + nm
      }]
    }));
    setWhereFor(w => w && {
      ...w,
      machine: tk,
      model: nm
    });
  }
  function setModel(model) {
    patch(whereFor.id, s => ({
      ...s,
      model
    }));
    setWhereFor(w => w && {
      ...w,
      model
    });
  }
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      flexDirection: "column",
      width: "100%",
      padding: "var(--space-l)",
      gap: "var(--space-s)",
      position: "relative"
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      position: "relative",
      display: "flex",
      alignItems: "center",
      gap: "var(--space-xs)"
    }
  }, /*#__PURE__*/React.createElement("button", {
    onClick: () => setDrawer(true),
    title: "All chats",
    style: {
      flex: 1,
      minWidth: 0,
      display: "flex",
      alignItems: "center",
      gap: 7,
      background: "none",
      border: "none",
      cursor: "pointer",
      padding: "4px 2px",
      textAlign: "left"
    }
  }, /*#__PURE__*/React.createElement(Icon, {
    name: "message-chatbot",
    size: 20,
    color: "var(--m-primary)"
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-bold) var(--text-l)/1.15 var(--font-sans)",
      color: "var(--m-on-surface)",
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis"
    }
  }, active.name), /*#__PURE__*/React.createElement(Icon, {
    name: "chevron-down",
    size: 15,
    color: "var(--m-on-surface-variant)"
  })), /*#__PURE__*/React.createElement(IconButton, {
    icon: "plus",
    size: 30,
    title: "New chat",
    onClick: () => setRunOn(true)
  }), /*#__PURE__*/React.createElement(IconButton, {
    icon: "dots-vertical",
    size: 30,
    title: "Options",
    onClick: () => setOverflow(v => !v)
  }), overflow ? /*#__PURE__*/React.createElement(OverflowMenu, {
    onClose: () => setOverflow(false),
    onSearch: () => {
      setSearchOpen(true);
      setOverflow(false);
    }
  }) : null), /*#__PURE__*/React.createElement("button", {
    onClick: () => setWhereFor(active),
    style: {
      display: "flex",
      alignItems: "center",
      gap: "var(--space-xs)",
      padding: "7px 10px",
      background: "var(--m-surface-variant)",
      border: "var(--border-width) solid var(--m-outline)",
      borderRadius: "var(--radius-input)",
      cursor: "pointer",
      width: "100%"
    }
  }, /*#__PURE__*/React.createElement(StatusDot, {
    status: reachable ? "online" : "offline",
    size: 8
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-bold) var(--text-s)/1 var(--font-mono)",
      color: machine.color,
      flexShrink: 0
    }
  }, machine.name), /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)",
      color: "var(--m-on-surface-variant)",
      overflow: "hidden",
      textOverflow: "ellipsis",
      whiteSpace: "nowrap"
    }
  }, "\xB7 ", active.model), /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)",
      color: "var(--m-secondary)",
      whiteSpace: "nowrap",
      flexShrink: 0
    }
  }, "Where it runs"), /*#__PURE__*/React.createElement(Icon, {
    name: "chevron-down",
    size: 14,
    color: "var(--m-secondary)"
  })), searchOpen ? /*#__PURE__*/React.createElement(SearchBar, {
    onClose: () => setSearchOpen(false)
  }) : null, /*#__PURE__*/React.createElement("div", {
    style: {
      height: "var(--border-width)",
      background: "var(--m-outline)"
    }
  }), /*#__PURE__*/React.createElement("div", {
    ref: listRef,
    style: {
      flex: 1,
      minHeight: 0,
      overflowY: "auto",
      display: "flex",
      flexDirection: "column",
      gap: "var(--space-m)",
      paddingRight: 2
    }
  }, active.messages.map(m => m.type === "confirm" ? /*#__PURE__*/React.createElement(ConfirmCard, {
    key: m.id,
    command: m.command,
    state: m.confirmState,
    machine: {
      name: machine.name,
      color: machine.color
    },
    onAllow: () => answerConfirm(m.id, true),
    onDeny: () => answerConfirm(m.id, false)
  }) : /*#__PURE__*/React.createElement(Bubble, {
    key: m.id,
    from: m.from,
    text: m.text,
    time: m.time,
    ack: m.ack,
    tps: m.tps,
    quote: m.quote,
    variant: m.type === "thinking" ? "thinking" : m.type === "notification" ? "notification" : "text"
  }))), !reachable ? /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: "var(--space-s)",
      padding: "var(--space-s) var(--space-m)",
      background: "var(--m-surface-variant)",
      border: "var(--border-width) solid var(--m-error)",
      borderRadius: "var(--radius-s)"
    }
  }, /*#__PURE__*/React.createElement(Icon, {
    name: "database-off",
    size: 16,
    color: "var(--m-error)"
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1,
      font: "var(--weight-medium) var(--text-s)/1.4 var(--font-sans)",
      color: "var(--m-on-surface)"
    }
  }, "Can\u2019t reach ", /*#__PURE__*/React.createElement("b", {
    style: {
      fontFamily: "var(--font-mono)",
      color: machine.color
    }
  }, machine.name), " \u2014 cached, read-only.")) : null, /*#__PURE__*/React.createElement(Compose, {
    draft: draft,
    setDraft: setDraft,
    send: send,
    reachable: reachable,
    machine: machine
  }), drawer ? /*#__PURE__*/React.createElement(ChatDrawer, {
    sessions: sessions,
    activeId: activeId,
    onClose: () => setDrawer(false),
    onPick: id => {
      setActiveId(id);
      setDrawer(false);
    },
    onNew: () => {
      setDrawer(false);
      setRunOn(true);
    }
  }) : null, runOn ? /*#__PURE__*/React.createElement(RunOnSheet, {
    onClose: () => setRunOn(false),
    onPick: startChat
  }) : null, whereFor ? /*#__PURE__*/React.createElement(WhereSheet, {
    sess: whereFor,
    onClose: () => setWhereFor(null),
    onMove: doMove,
    onModel: setModel
  }) : null);
}
function OverflowMenu({
  onClose,
  onSearch
}) {
  const rows = [{
    icon: "search",
    label: "Search messages",
    onClick: onSearch
  }, {
    icon: "brain",
    label: "Long-term memory: on",
    onClick: onClose
  }, {
    icon: "rotate",
    label: "Restart conversation",
    onClick: onClose
  }, {
    icon: "eye",
    label: "Hide thinking",
    onClick: onClose
  }, {
    icon: "eraser",
    label: "Wipe memory",
    onClick: onClose,
    danger: true
  }];
  return /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("div", {
    onClick: onClose,
    style: {
      position: "fixed",
      inset: 0,
      zIndex: 24
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      position: "absolute",
      top: 38,
      right: 0,
      zIndex: 25,
      minWidth: 210,
      background: "var(--m-surface-variant)",
      border: "var(--border-width) solid var(--m-outline)",
      borderRadius: "var(--radius-input)",
      boxShadow: "var(--shadow-popup)",
      padding: "var(--space-xs)"
    }
  }, rows.map(r => /*#__PURE__*/React.createElement("div", {
    key: r.label,
    className: "sos-menu-row",
    onClick: r.onClick,
    style: {
      display: "flex",
      alignItems: "center",
      gap: 10,
      padding: "8px 9px",
      borderRadius: "var(--radius-s)",
      cursor: "pointer",
      font: "var(--weight-medium) var(--text-s)/1 var(--font-sans)",
      color: r.danger ? "var(--m-error)" : "var(--m-on-surface)"
    }
  }, /*#__PURE__*/React.createElement(Icon, {
    name: r.icon,
    size: 16,
    color: r.danger ? "var(--m-error)" : "var(--m-on-surface-variant)"
  }), r.label))));
}
function SearchBar({
  onClose
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: "var(--space-s)"
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      display: "flex",
      background: "var(--m-surface-variant)",
      border: "var(--border-width) solid var(--m-secondary)",
      borderRadius: "var(--radius-input)",
      padding: "var(--space-s) var(--space-m)"
    }
  }, /*#__PURE__*/React.createElement("input", {
    autoFocus: true,
    placeholder: "Search messages\u2026",
    style: {
      width: "100%",
      background: "transparent",
      border: "none",
      outline: "none",
      color: "var(--m-on-surface)",
      font: "var(--weight-medium) var(--text-m)/1 var(--font-sans)"
    }
  })), /*#__PURE__*/React.createElement(IconButton, {
    icon: "x",
    size: 28,
    title: "Close search",
    onClick: onClose
  }));
}
function Compose({
  draft,
  setDraft,
  send,
  reachable,
  machine
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "flex-end",
      gap: "var(--space-s)"
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      display: "flex",
      background: "var(--m-surface)",
      border: "var(--border-width) solid var(--m-outline)",
      borderRadius: "var(--radius-input)",
      opacity: reachable ? 1 : 0.5
    }
  }, /*#__PURE__*/React.createElement("textarea", {
    value: draft,
    disabled: !reachable,
    onChange: e => setDraft(e.target.value),
    onKeyDown: e => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        send();
      }
    },
    placeholder: reachable ? "Message " + machine.name + "…" : "Unreachable — read-only",
    rows: 1,
    style: {
      width: "100%",
      resize: "none",
      background: "transparent",
      border: "none",
      outline: "none",
      color: "var(--m-on-surface)",
      font: "var(--weight-medium) var(--text-m)/1.4 var(--font-sans)",
      padding: "var(--space-s) var(--space-m)",
      maxHeight: 120
    }
  })), /*#__PURE__*/React.createElement(IconButton, {
    icon: "microphone",
    size: 36,
    title: "Voice to text",
    disabled: !reachable
  }), /*#__PURE__*/React.createElement(IconButton, {
    icon: "paperclip",
    size: 36,
    title: "Attach image",
    disabled: !reachable
  }), /*#__PURE__*/React.createElement(IconButton, {
    icon: "send",
    size: 36,
    title: "Send",
    disabled: !reachable || !draft.trim(),
    onClick: send
  }));
}

/* ============================ chat drawer (scales) ============================ */
function ChatDrawer({
  sessions,
  activeId,
  onClose,
  onPick,
  onNew
}) {
  const [filter, setFilter] = useState("all");
  const machines = Object.values(MACHINES);
  const shown = sessions.filter(s => filter === "all" || s.machine === filter);
  return /*#__PURE__*/React.createElement("div", {
    onClick: onClose,
    style: {
      position: "absolute",
      inset: 0,
      background: "rgba(5,5,19,0.6)",
      backdropFilter: "blur(2px)",
      borderRadius: "var(--radius-s) 0 0 0",
      zIndex: 30
    }
  }, /*#__PURE__*/React.createElement("div", {
    onClick: e => e.stopPropagation(),
    style: {
      position: "absolute",
      top: 0,
      left: 0,
      right: 0,
      maxHeight: "82%",
      display: "flex",
      flexDirection: "column",
      background: "var(--m-surface)",
      borderBottom: "var(--border-width) solid var(--m-outline)",
      borderRadius: "var(--radius-s) 0 var(--radius-s) var(--radius-s)",
      boxShadow: "var(--shadow-popup)"
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: "var(--space-s)",
      padding: "var(--space-m) var(--space-l)"
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1,
      font: "var(--weight-bold) var(--text-l)/1 var(--font-sans)",
      color: "var(--m-on-surface)"
    }
  }, "Chats"), /*#__PURE__*/React.createElement(Button, {
    icon: "plus",
    onClick: onNew
  }, "New"), /*#__PURE__*/React.createElement(IconButton, {
    icon: "x",
    size: 28,
    title: "Close",
    onClick: onClose
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      gap: "var(--space-xs)",
      padding: "0 var(--space-l) var(--space-s)",
      overflowX: "auto"
    }
  }, /*#__PURE__*/React.createElement(DrawerFilter, {
    label: "All",
    active: filter === "all",
    onClick: () => setFilter("all")
  }), machines.map(m => /*#__PURE__*/React.createElement("button", {
    key: m.name,
    onClick: () => setFilter(m.name),
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: 6,
      height: 26,
      padding: "0 10px",
      flexShrink: 0,
      borderRadius: "var(--radius-input)",
      cursor: "pointer",
      whiteSpace: "nowrap",
      background: filter === m.name ? m.color : "var(--m-surface-variant)",
      border: "var(--border-width) solid " + (filter === m.name ? "transparent" : "var(--m-outline)"),
      color: filter === m.name ? "var(--m-on-primary)" : m.color,
      font: "var(--weight-medium) var(--text-s)/1 var(--font-mono)"
    }
  }, /*#__PURE__*/React.createElement(StatusDot, {
    status: m.status,
    size: 6
  }), m.name))), /*#__PURE__*/React.createElement("div", {
    style: {
      overflowY: "auto",
      padding: "0 var(--space-s) var(--space-s)",
      display: "flex",
      flexDirection: "column",
      gap: "var(--space-xs)"
    }
  }, shown.map(s => /*#__PURE__*/React.createElement(ChatRow, {
    key: s.id,
    s: s,
    active: s.id === activeId,
    onClick: () => onPick(s.id)
  })))));
}
function DrawerFilter({
  label,
  active,
  onClick
}) {
  return /*#__PURE__*/React.createElement("button", {
    onClick: onClick,
    style: {
      height: 26,
      padding: "0 12px",
      flexShrink: 0,
      borderRadius: "var(--radius-input)",
      cursor: "pointer",
      background: active ? "var(--m-on-surface)" : "var(--m-surface-variant)",
      border: "var(--border-width) solid " + (active ? "transparent" : "var(--m-outline)"),
      color: active ? "var(--m-surface)" : "var(--m-on-surface)",
      font: "var(--weight-semibold) var(--text-s)/1 var(--font-sans)"
    }
  }, label);
}
function ChatRow({
  s,
  active,
  onClick
}) {
  const m = MACHINES[s.machine];
  const state = chatState(s);
  const unreachable = state === "unreachable";
  return /*#__PURE__*/React.createElement("button", {
    onClick: onClick,
    style: {
      width: "100%",
      textAlign: "left",
      display: "flex",
      gap: "var(--space-s)",
      alignItems: "stretch",
      padding: "var(--space-s) var(--space-m)",
      background: active ? "var(--m-surface-variant)" : "transparent",
      border: "var(--border-width) solid " + (active ? "var(--m-outline)" : "transparent"),
      borderRadius: "var(--radius-s)",
      cursor: "pointer",
      opacity: unreachable ? 0.6 : 1
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      width: 3,
      alignSelf: "stretch",
      borderRadius: 2,
      background: m.color,
      flexShrink: 0
    }
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      minWidth: 0
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: 8
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1,
      font: "var(--weight-bold) var(--text-m)/1.2 var(--font-sans)",
      color: "var(--m-on-surface)",
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis"
    }
  }, s.name), /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)",
      color: "var(--m-on-surface-variant)",
      flexShrink: 0
    }
  }, s.time)), /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--weight-medium) var(--text-s)/1.35 var(--font-sans)",
      color: "var(--m-on-surface-variant)",
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis",
      marginTop: 2
    }
  }, s.preview), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: 8,
      marginTop: 6
    }
  }, /*#__PURE__*/React.createElement(MachineChip, {
    name: m.name,
    color: m.color,
    status: m.status,
    relayed: m.relayed,
    size: "sm"
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1
    }
  }), /*#__PURE__*/React.createElement(ChatBadge, {
    state: state,
    unread: s.unread
  }))));
}
function ChatBadge({
  state,
  unread
}) {
  if (state === "needs-you") return /*#__PURE__*/React.createElement("span", {
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: 5,
      height: 19,
      padding: "0 8px",
      borderRadius: "var(--radius-input)",
      background: "var(--m-primary)",
      color: "var(--m-on-primary)",
      font: "var(--weight-bold) var(--text-xs)/1 var(--font-sans)"
    }
  }, /*#__PURE__*/React.createElement(Icon, {
    name: "key",
    size: 11
  }), "needs you");
  if (state === "working") return /*#__PURE__*/React.createElement("span", {
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: 5,
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)",
      color: "var(--m-primary)"
    }
  }, /*#__PURE__*/React.createElement(StatusDot, {
    status: "working",
    size: 7
  }), "working");
  if (state === "unreachable") return /*#__PURE__*/React.createElement("span", {
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: 5,
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)",
      color: "var(--m-on-surface-variant)"
    }
  }, /*#__PURE__*/React.createElement(Icon, {
    name: "database-off",
    size: 12
  }), "offline");
  if (unread > 0) return /*#__PURE__*/React.createElement("span", {
    style: {
      minWidth: 18,
      height: 18,
      padding: "0 5px",
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      borderRadius: "var(--radius-xs)",
      background: "var(--m-primary)",
      color: "var(--m-on-primary)",
      font: "var(--weight-bold) var(--text-xs)/1 var(--font-sans)"
    }
  }, unread);
  return null;
}

/* ============================ sheets ============================ */
function Scrim({
  onClose,
  children
}) {
  return /*#__PURE__*/React.createElement("div", {
    onClick: onClose,
    style: {
      position: "absolute",
      inset: 0,
      background: "rgba(5,5,19,0.82)",
      backdropFilter: "blur(3px)",
      borderRadius: "var(--radius-s) 0 0 0",
      display: "flex",
      alignItems: "flex-start",
      justifyContent: "center",
      paddingTop: 60,
      zIndex: 35
    }
  }, /*#__PURE__*/React.createElement("div", {
    onClick: e => e.stopPropagation(),
    style: {
      width: PANEL_W - 52,
      background: "var(--m-surface)",
      border: "var(--border-width) solid var(--m-outline)",
      borderRadius: "var(--radius-s)",
      boxShadow: "var(--shadow-popup)",
      overflow: "hidden"
    }
  }, children));
}
function SheetHead({
  title,
  sub,
  roadmap,
  onClose
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "flex-start",
      gap: "var(--space-s)",
      padding: "var(--space-m)",
      borderBottom: "var(--border-width) solid var(--m-outline)"
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: 8
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-bold) var(--text-l)/1.2 var(--font-sans)",
      color: "var(--m-on-surface)",
      whiteSpace: "nowrap"
    }
  }, title), roadmap ? /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-bold) var(--text-xs)/1 var(--font-mono)",
      color: "var(--m-on-tertiary)",
      background: "var(--m-tertiary)",
      borderRadius: "var(--radius-xs)",
      padding: "2px 7px"
    }
  }, "ROADMAP") : null), sub ? /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--weight-medium) var(--text-s)/1.4 var(--font-sans)",
      color: "var(--m-on-surface-variant)",
      marginTop: 3
    }
  }, sub) : null), /*#__PURE__*/React.createElement(IconButton, {
    icon: "x",
    size: 26,
    title: "Close",
    onClick: onClose
  }));
}
function MachineRow({
  m,
  disabled,
  reason,
  right,
  onClick
}) {
  return /*#__PURE__*/React.createElement("div", {
    onClick: disabled ? undefined : onClick,
    className: disabled ? "" : "sos-menu-row",
    style: {
      display: "flex",
      alignItems: "center",
      gap: "var(--space-s)",
      padding: "var(--space-m)",
      cursor: disabled ? "default" : "pointer",
      opacity: disabled ? 0.5 : 1
    }
  }, /*#__PURE__*/React.createElement(StatusDot, {
    status: m.status,
    size: 10
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1,
      minWidth: 0
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: 8,
      whiteSpace: "nowrap",
      overflow: "hidden"
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-bold) var(--text-m)/1 var(--font-mono)",
      color: m.color
    }
  }, m.name), /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)",
      color: "var(--m-on-surface-variant)"
    }
  }, m.role), m.relayed ? /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)",
      color: "var(--m-on-surface-variant)"
    }
  }, "\xB7 relayed") : null), /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1.4 var(--font-mono)",
      color: disabled ? "var(--m-error)" : "var(--m-on-surface-variant)",
      marginTop: 4,
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis"
    }
  }, reason || m.models.join(" · "))), right || (!disabled ? /*#__PURE__*/React.createElement(Icon, {
    name: "chevron-down",
    size: 16,
    color: "var(--m-on-surface-variant)",
    style: {
      transform: "rotate(-90deg)"
    }
  }) : null));
}
function RunOnSheet({
  onClose,
  onPick
}) {
  return /*#__PURE__*/React.createElement(Scrim, {
    onClose: onClose
  }, /*#__PURE__*/React.createElement(SheetHead, {
    title: "Start a chat",
    sub: "Pick the machine that will run the agent. Its models are scoped to that machine.",
    onClose: onClose
  }), Object.values(MACHINES).map((m, i) => {
    const off = m.status === "offline";
    return /*#__PURE__*/React.createElement("div", {
      key: m.name,
      style: {
        borderTop: i ? "var(--border-width) solid var(--m-outline)" : "none"
      }
    }, /*#__PURE__*/React.createElement(MachineRow, {
      m: m,
      disabled: off,
      reason: off ? "unreachable — can’t start a chat here" : undefined,
      onClick: () => onPick(m.name)
    }));
  }));
}

/* "Where this runs" — reframed move: machine + model unified in one sheet. */
function WhereSheet({
  sess,
  onClose,
  onMove,
  onModel
}) {
  const [mem, setMem] = useState(false);
  const cur = MACHINES[sess.machine];
  const sourceReachable = cur.status !== "offline";
  return /*#__PURE__*/React.createElement(Scrim, {
    onClose: onClose
  }, /*#__PURE__*/React.createElement(SheetHead, {
    title: "Where this runs",
    sub: "This chat is a process on a machine. Point it wherever it should run \u2014 same chat, new home.",
    onClose: onClose
  }), !sourceReachable ? /*#__PURE__*/React.createElement("div", {
    style: {
      margin: "var(--space-m) var(--space-m) 0",
      padding: "var(--space-s) var(--space-m)",
      background: "var(--m-surface-variant)",
      border: "var(--border-width) solid var(--m-error)",
      borderRadius: "var(--radius-s)",
      font: "var(--weight-medium) var(--text-xs)/1.4 var(--font-sans)",
      color: "var(--m-on-surface)"
    }
  }, /*#__PURE__*/React.createElement("b", {
    style: {
      fontFamily: "var(--font-mono)",
      color: cur.color
    }
  }, cur.name), " is offline \u2014 reconnect before moving.") : null, /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)",
      color: "var(--m-on-surface-variant)",
      textTransform: "uppercase",
      letterSpacing: "var(--tracking-wide)",
      padding: "var(--space-m) var(--space-m) var(--space-xs)"
    }
  }, "machine"), Object.values(MACHINES).map(m => {
    const current = m.name === sess.machine,
      off = m.status === "offline";
    const disabled = off || !current && !sourceReachable;
    const keeps = m.models.includes(sess.model);
    const reason = current ? "current home" : off ? "unreachable" : keeps ? "keeps " + sess.model : sess.model + " → " + m.models[0];
    return /*#__PURE__*/React.createElement("div", {
      key: m.name,
      style: {
        borderTop: "var(--border-width) solid var(--m-outline)"
      }
    }, /*#__PURE__*/React.createElement(MachineRow, {
      m: m,
      disabled: disabled && !current,
      reason: reason,
      onClick: !disabled && !current ? () => onMove(m.name) : undefined,
      right: current ? /*#__PURE__*/React.createElement(Icon, {
        name: "check",
        size: 16,
        color: "var(--m-primary)"
      }) : !disabled ? /*#__PURE__*/React.createElement("span", {
        style: {
          font: "var(--weight-semibold) var(--text-xs)/1 var(--font-sans)",
          color: "var(--m-secondary)"
        }
      }, "move") : null
    }));
  }), /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)",
      color: "var(--m-on-surface-variant)",
      textTransform: "uppercase",
      letterSpacing: "var(--tracking-wide)",
      padding: "var(--space-m) var(--space-m) var(--space-xs)",
      borderTop: "var(--border-width) solid var(--m-outline)"
    }
  }, "model on ", cur.name), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      flexWrap: "wrap",
      gap: 7,
      padding: "0 var(--space-m) var(--space-s)"
    }
  }, cur.models.map(mod => {
    const on = mod === sess.model;
    return /*#__PURE__*/React.createElement("button", {
      key: mod,
      onClick: () => onModel(mod),
      style: {
        display: "inline-flex",
        alignItems: "center",
        gap: 6,
        height: 28,
        padding: "0 11px",
        borderRadius: "var(--radius-input)",
        cursor: "pointer",
        background: on ? "var(--m-primary)" : "var(--m-surface-variant)",
        border: "var(--border-width) solid " + (on ? "transparent" : "var(--m-outline)"),
        color: on ? "var(--m-on-primary)" : "var(--m-on-surface)",
        font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)"
      }
    }, on ? /*#__PURE__*/React.createElement(Icon, {
      name: "check",
      size: 12
    }) : null, mod);
  })), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: "var(--space-s)",
      padding: "var(--space-m)",
      borderTop: "var(--border-width) solid var(--m-outline)",
      background: "var(--m-surface-variant)"
    }
  }, /*#__PURE__*/React.createElement("button", {
    onClick: () => setMem(v => !v),
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: 8,
      background: "none",
      border: "none",
      cursor: "pointer",
      padding: 0
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      width: 18,
      height: 18,
      borderRadius: 4,
      border: "var(--border-width) solid var(--m-outline)",
      background: mem ? "var(--m-primary)" : "transparent",
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center"
    }
  }, mem ? /*#__PURE__*/React.createElement(Icon, {
    name: "check",
    size: 13,
    color: "var(--m-on-primary)"
  }) : null), /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-s)/1.3 var(--font-sans)",
      color: "var(--m-on-surface)",
      whiteSpace: "nowrap"
    }
  }, "Bring memory when moving")), /*#__PURE__*/React.createElement("span", {
    style: {
      flex: 1
    }
  }), /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1.3 var(--font-sans)",
      color: "var(--m-on-surface-variant)",
      textAlign: "right"
    }
  }, mem ? "copies sediment" : "stays on " + cur.name)));
}
const _st = document.createElement("style");
_st.textContent = ".sos-menu-row:hover{background:var(--m-hover);color:var(--m-on-hover)!important}.sos-menu-row:hover *{color:var(--m-on-hover)!important}";
document.head.appendChild(_st);
ReactDOM.createRoot(document.getElementById("root")).render(/*#__PURE__*/React.createElement(App, null));
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/quickshell-panel/panel.jsx", error: String((e && e.message) || e) }); }

// ui_kits/shared/kit.jsx
try { (() => {
// Shared Spaces OS kit components for the UI-kit prototypes (panel + PWA).
// These mirror the design-system primitives 1:1 visually but are
// self-contained so the click-through kits render without the compiled
// bundle. All driven by the token CSS variables from styles.css.
// Exposed on window.SOS for the per-kit Babel scripts.
const {
  useState,
  useEffect,
  useRef
} = React;

/* ---------- Icon (runtime-inlined Tabler SVG, recolours via color) ---------- */
const _iconCache = {};
function Icon({
  name,
  size = 20,
  color,
  style = {},
  strokeWidth
}) {
  const [svg, setSvg] = useState(_iconCache[name] || "");
  useEffect(() => {
    let live = true;
    if (_iconCache[name]) {
      setSvg(_iconCache[name]);
      return;
    }
    fetch(`../../assets/icons/${name}.svg`).then(r => r.text()).then(t => {
      if (strokeWidth) t = t.replace(/stroke-width="2"/, `stroke-width="${strokeWidth}"`);
      _iconCache[name] = t;
      if (live) setSvg(t);
    }).catch(() => {});
    return () => {
      live = false;
    };
  }, [name]);
  return /*#__PURE__*/React.createElement("span", {
    "aria-hidden": "true",
    style: {
      display: "inline-flex",
      width: size,
      height: size,
      color: color || "currentColor",
      flexShrink: 0,
      ...style
    },
    ref: el => {
      if (el && svg) {
        const s = el.querySelector("svg");
        if (!s || s.dataset.n !== name) {
          el.innerHTML = svg;
          const ns = el.querySelector("svg");
          if (ns) {
            ns.setAttribute("width", size);
            ns.setAttribute("height", size);
            ns.style.display = "block";
            ns.dataset.n = name;
          }
        }
      }
    }
  });
}

/* ---------- StatusDot ---------- */
const DOT = {
  online: {
    c: "var(--m-tertiary)",
    pulse: false
  },
  offline: {
    c: "var(--m-error)",
    pulse: false
  },
  working: {
    c: "var(--m-primary)",
    pulse: true
  },
  idle: {
    c: "var(--m-on-surface-variant)",
    pulse: false
  }
};
function StatusDot({
  status = "online",
  size = 8,
  style = {}
}) {
  const s = DOT[status] || DOT.idle;
  return /*#__PURE__*/React.createElement("span", {
    style: {
      display: "inline-block",
      width: size,
      height: size,
      borderRadius: "50%",
      background: s.c,
      flexShrink: 0,
      animation: s.pulse ? "sos-pulse 1.4s var(--ease-standard) infinite" : "none",
      ...style
    }
  });
}

/* ---------- MachineChip ---------- */
function MachineChip({
  name,
  color = "var(--m-primary)",
  status,
  relayed,
  size = "md",
  variant = "outline",
  style = {},
  onClick
}) {
  const dim = size === "sm" ? {
    h: 20,
    f: "var(--text-xs)",
    dot: 6
  } : {
    h: 26,
    f: "var(--text-s)",
    dot: 8
  };
  const solid = variant === "solid";
  const bg = solid ? color : variant === "ghost" ? "transparent" : "var(--m-surface-variant)";
  const label = solid ? "var(--m-on-primary)" : color;
  const border = variant === "outline" ? "var(--border-width) solid var(--m-outline)" : "var(--border-width) solid transparent";
  return /*#__PURE__*/React.createElement("span", {
    onClick: onClick,
    style: {
      display: "inline-flex",
      alignItems: "center",
      gap: "var(--space-xs)",
      height: dim.h,
      padding: "0 var(--space-s)",
      background: bg,
      border,
      borderRadius: "var(--radius-input)",
      font: `var(--weight-medium) ${dim.f}/1 var(--font-mono)`,
      color: label,
      whiteSpace: "nowrap",
      cursor: onClick ? "pointer" : "default",
      ...style
    }
  }, status ? /*#__PURE__*/React.createElement(StatusDot, {
    status: status,
    size: dim.dot
  }) : null, /*#__PURE__*/React.createElement("span", null, name), relayed ? /*#__PURE__*/React.createElement(Icon, {
    name: "rotate",
    size: dim.dot + 4,
    style: {
      opacity: 0.7
    }
  }) : null);
}

/* ---------- Button ---------- */
const BTN = {
  primary: {
    background: "var(--m-primary)",
    color: "var(--m-on-primary)"
  },
  neutral: {
    background: "var(--m-surface-variant)",
    color: "var(--m-on-surface)"
  },
  danger: {
    background: "var(--m-error)",
    color: "var(--m-on-error)"
  }
};
function Button({
  children,
  icon,
  variant = "primary",
  disabled,
  onClick,
  style = {}
}) {
  const v = BTN[variant] || BTN.primary;
  const [h, setH] = useState(false);
  return /*#__PURE__*/React.createElement("button", {
    type: "button",
    disabled: disabled,
    onClick: onClick,
    onMouseEnter: () => setH(true),
    onMouseLeave: () => setH(false),
    style: {
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      gap: "var(--space-xs)",
      height: 28,
      padding: "0 var(--space-l)",
      font: `var(--weight-medium) var(--text-m)/1 var(--font-sans)`,
      color: v.color,
      background: v.background,
      border: "var(--border-width) solid var(--m-outline)",
      borderRadius: "var(--radius-input)",
      cursor: disabled ? "default" : "pointer",
      opacity: disabled ? 0.6 : 1,
      filter: h && !disabled ? "brightness(1.1)" : "none",
      transition: "filter var(--duration-fast) var(--ease-standard)",
      whiteSpace: "nowrap",
      ...style
    }
  }, icon ? /*#__PURE__*/React.createElement(Icon, {
    name: icon,
    size: 15
  }) : null, children);
}

/* ---------- IconButton ---------- */
function IconButton({
  icon,
  size = 33,
  active,
  disabled,
  title,
  onClick,
  style = {}
}) {
  const [h, setH] = useState(false);
  const radius = Math.min(6, size / 2);
  const hovering = h && !disabled;
  let bg, fg, border;
  if (active) {
    bg = "var(--m-error)";
    fg = "var(--m-on-error)";
    border = "var(--m-error)";
  } else if (hovering) {
    bg = "var(--m-hover)";
    fg = "var(--m-on-hover)";
    border = "var(--m-outline)";
  } else {
    bg = "var(--m-surface-variant)";
    fg = "var(--m-primary)";
    border = "var(--m-outline)";
  }
  return /*#__PURE__*/React.createElement("button", {
    type: "button",
    title: title,
    disabled: disabled,
    onClick: onClick,
    onMouseEnter: () => setH(true),
    onMouseLeave: () => setH(false),
    style: {
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      width: size,
      height: size,
      padding: 0,
      background: bg,
      color: fg,
      border: `var(--border-width) solid ${border}`,
      borderRadius: radius,
      cursor: disabled ? "default" : "pointer",
      opacity: disabled ? 0.6 : 1,
      transition: "background var(--duration-fast) var(--ease-standard), color var(--duration-fast) var(--ease-standard)",
      ...style
    }
  }, /*#__PURE__*/React.createElement(Icon, {
    name: icon,
    size: Math.max(14, Math.round(size * 0.45))
  }));
}

/* ---------- Bubble ---------- */
const ACK = {
  pending: "🕓",
  sent: "✓",
  read: "✓✓",
  warn: "⚠"
};
function Bubble({
  from = "peer",
  text = "",
  time,
  ack,
  tps,
  quote,
  variant = "text",
  streaming,
  style = {}
}) {
  const mine = from === "me";
  if (variant === "notification") return /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      justifyContent: "center",
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      maxWidth: "85%",
      textAlign: "center",
      color: "var(--overlay-on-surface-45)",
      font: "var(--weight-medium) var(--text-s)/1.4 var(--font-sans)"
    }
  }, text));
  if (variant === "thinking") return /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      maxWidth: "85%",
      fontStyle: "italic",
      font: "italic var(--weight-medium) var(--text-s)/1.5 var(--font-sans)",
      color: "var(--overlay-on-surface-45)"
    }
  }, text || "thinking…"));
  return /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      justifyContent: mine ? "flex-end" : "flex-start",
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      maxWidth: "85%",
      background: mine ? "var(--m-primary)" : "var(--m-surface-variant)",
      color: mine ? "var(--m-on-primary)" : "var(--m-on-surface)",
      border: mine ? "none" : "var(--border-width) solid var(--m-outline)",
      borderRadius: "var(--radius-s)",
      padding: "var(--space-m)",
      display: "flex",
      flexDirection: "column",
      gap: "var(--space-xxs)"
    }
  }, quote ? /*#__PURE__*/React.createElement("div", {
    style: {
      background: mine ? "var(--overlay-on-primary-15)" : "var(--overlay-on-surface-08)",
      color: mine ? "var(--overlay-on-primary-60)" : "var(--m-on-surface-variant)",
      borderRadius: "var(--radius-xs)",
      padding: "var(--space-xs) var(--space-s)",
      font: "var(--weight-medium) var(--text-xs)/1.4 var(--font-sans)",
      whiteSpace: "nowrap",
      overflow: "hidden",
      textOverflow: "ellipsis"
    }
  }, "\u21B3 ", quote) : null, /*#__PURE__*/React.createElement("div", {
    style: {
      font: "var(--weight-medium) var(--text-m)/1.5 var(--font-sans)",
      whiteSpace: "pre-wrap",
      wordBreak: "break-word"
    }
  }, text, streaming ? /*#__PURE__*/React.createElement("span", {
    style: {
      marginLeft: 2,
      opacity: 0.7
    }
  }, "\u258D") : null), /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      gap: "var(--space-xs)",
      justifyContent: mine ? "flex-end" : "flex-start"
    }
  }, time ? /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)",
      color: mine ? "var(--overlay-on-primary-60)" : "var(--m-on-surface-variant)"
    }
  }, time) : null, !mine && tps ? /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-mono)",
      color: "var(--m-on-surface-variant)"
    }
  }, tps.toFixed(1), " t/s") : null, mine && ack ? /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--text-s)/1 var(--font-sans)",
      color: ack === "warn" ? "var(--m-error)" : "var(--overlay-on-primary-80)"
    }
  }, ACK[ack]) : null)));
}

/* ---------- ConfirmCard ---------- */
function ConfirmCard({
  title = "Run shell command?",
  command = "",
  state = "pending",
  machine,
  answeredBy,
  onAllow,
  onDeny,
  style = {}
}) {
  const bc = state === "allowed" ? "var(--m-tertiary)" : state === "denied" ? "var(--m-error)" : "var(--m-primary)";
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: "var(--m-surface-variant)",
      border: `var(--border-width) solid ${bc}`,
      borderRadius: "var(--radius-s)",
      padding: "var(--space-m)",
      display: "flex",
      flexDirection: "column",
      gap: "var(--space-s)",
      ...style
    }
  }, /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      alignItems: "center",
      justifyContent: "space-between",
      gap: "var(--space-s)"
    }
  }, /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-bold) var(--text-m)/1.2 var(--font-sans)",
      color: "var(--m-on-surface)"
    }
  }, title), machine ? /*#__PURE__*/React.createElement(MachineChip, {
    name: machine.name,
    color: machine.color,
    size: "sm"
  }) : null), /*#__PURE__*/React.createElement("pre", {
    style: {
      margin: 0,
      background: "var(--m-surface)",
      border: "var(--border-width) solid var(--m-outline)",
      borderRadius: "var(--radius-xs)",
      padding: "var(--space-s) var(--space-m)",
      font: "var(--weight-medium) var(--text-s)/1.5 var(--font-mono)",
      color: "var(--m-on-surface)",
      whiteSpace: "pre-wrap",
      wordBreak: "break-all"
    }
  }, command), state === "pending" ? /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      justifyContent: "flex-end",
      gap: "var(--space-s)"
    }
  }, /*#__PURE__*/React.createElement(Button, {
    variant: "neutral",
    onClick: onDeny
  }, "Deny"), /*#__PURE__*/React.createElement(Button, {
    variant: "primary",
    onClick: onAllow
  }, "Allow")) : /*#__PURE__*/React.createElement("div", {
    style: {
      display: "flex",
      justifyContent: "flex-end",
      alignItems: "center",
      gap: "var(--space-s)"
    }
  }, answeredBy ? /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-medium) var(--text-xs)/1 var(--font-sans)",
      color: "var(--m-on-surface-variant)"
    }
  }, answeredBy) : null, /*#__PURE__*/React.createElement("span", {
    style: {
      font: "var(--weight-bold) var(--text-s)/1 var(--font-sans)",
      color: state === "allowed" ? "var(--m-tertiary)" : "var(--m-error)"
    }
  }, state === "allowed" ? "✓ allowed" : "✗ denied")));
}

/* ---------- TextInput ---------- */
function TextInput({
  multiline,
  tone = "default",
  value,
  onChange,
  placeholder,
  rows = 1,
  style = {}
}) {
  const [focus, setFocus] = useState(false);
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
    font: "var(--weight-medium) var(--text-m)/1.4 var(--font-sans)",
    padding: "var(--space-s) var(--space-m)"
  };
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: bg,
      border: `var(--border-width) solid ${focus ? focusColor : "var(--m-outline)"}`,
      borderRadius: "var(--radius-input)",
      transition: "border-color var(--duration-fast) var(--ease-standard)",
      display: "flex",
      ...style
    }
  }, multiline ? /*#__PURE__*/React.createElement("textarea", {
    rows: rows,
    value: value,
    onChange: onChange,
    placeholder: placeholder,
    onFocus: () => setFocus(true),
    onBlur: () => setFocus(false),
    style: shared
  }) : /*#__PURE__*/React.createElement("input", {
    type: "text",
    value: value,
    onChange: onChange,
    placeholder: placeholder,
    onFocus: () => setFocus(true),
    onBlur: () => setFocus(false),
    style: shared
  }));
}

/* ---------- Divider ---------- */
function Divider({
  vertical,
  style = {}
}) {
  return /*#__PURE__*/React.createElement("div", {
    style: {
      background: "var(--m-outline)",
      flexShrink: 0,
      ...(vertical ? {
        width: "var(--border-width)",
        alignSelf: "stretch"
      } : {
        height: "var(--border-width)",
        width: "100%"
      }),
      ...style
    }
  });
}

/* ---------- shared machine catalogue (used by both kits) ---------- */
const MACHINES = {
  kiwi: {
    name: "kiwi",
    color: "var(--m-primary)",
    role: "desktop",
    status: "online",
    relayed: false,
    models: ["gemma3:27b", "qwen2.5-coder:14b", "llama3.2:3b"]
  },
  studio: {
    name: "studio",
    color: "var(--m-secondary)",
    role: "workstation",
    status: "offline",
    relayed: false,
    models: ["llama3.3:70b", "deepseek-r1:32b", "qwen2.5-coder:32b"]
  },
  nas: {
    name: "nas",
    color: "var(--m-tertiary)",
    role: "home server",
    status: "online",
    relayed: true,
    models: ["qwen2.5:7b", "phi4:14b"]
  }
};
window.SOS = {
  Icon,
  StatusDot,
  MachineChip,
  Button,
  IconButton,
  TextInput,
  Divider,
  Bubble,
  ConfirmCard,
  MACHINES
};

// keyframes once
if (!document.getElementById("sos-kf")) {
  const st = document.createElement("style");
  st.id = "sos-kf";
  st.textContent = "@keyframes sos-pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.45;transform:scale(.8)}}";
  document.head.appendChild(st);
}
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/shared/kit.jsx", error: String((e && e.message) || e) }); }

__ds_ns.Bubble = __ds_scope.Bubble;

__ds_ns.ConfirmCard = __ds_scope.ConfirmCard;

__ds_ns.Button = __ds_scope.Button;

__ds_ns.Divider = __ds_scope.Divider;

__ds_ns.ICON_PATHS = __ds_scope.ICON_PATHS;

__ds_ns.Icon = __ds_scope.Icon;

__ds_ns.IconButton = __ds_scope.IconButton;

__ds_ns.MachineChip = __ds_scope.MachineChip;

__ds_ns.StatusDot = __ds_scope.StatusDot;

__ds_ns.TextInput = __ds_scope.TextInput;

})();
