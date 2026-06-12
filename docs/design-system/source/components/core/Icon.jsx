// Icon — Spaces OS iconography.
//
// Tabler Icons (outline), MIT licensed — the exact set vendored in the
// pi-chat panel (programs/pi-chat/icons). 24x24 grid, 2px stroke,
// round caps/joins, drawn in currentColor so the glyph takes the CSS
// `color` of its context. Names match the source SVG filenames.
import React from "react";

export const ICON_PATHS = {
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
  "x": "<path d=\"M18 6l-12 12\"></path>\n  <path d=\"M6 6l12 12\"></path>",
};

export function Icon({ name, size = 20, strokeWidth = 2, className = "", style = {}, title, ...rest }) {
  const inner = ICON_PATHS[name];
  if (inner === undefined) {
    if (typeof console !== "undefined") console.warn("Icon: unknown name", name);
    return null;
  }
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      style={{ display: "block", flexShrink: 0, ...style }}
      role={title ? "img" : "presentation"}
      aria-label={title}
      aria-hidden={title ? undefined : true}
      dangerouslySetInnerHTML={{ __html: inner }}
      {...rest}
    />
  );
}
