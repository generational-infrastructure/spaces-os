// Kin / Spaces OS line-icon glyph set (QML port of lib/icon.ts).
//
// Inner SVG markup for each glyph on a 24×24 grid, thin rounded strokes.
// KinIcon wraps a chosen glyph in an <svg> with the stroke colour baked in
// and renders it as a data-URI Image. Only the glyphs the two screens use
// are carried here; add more from the web set as needed.
pragma Singleton

import QtQuick

QtObject {
  readonly property var paths: ({
      "search": '<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>',
      "plus": '<path d="M12 5v14M5 12h14"/>',
      "check": '<path d="M20 6 9 17l-5-5"/>',
      "chevron-down": '<path d="m6 9 6 6 6-6"/>',
      "arrow-up-right": '<path d="M7 17 17 7M8 7h9v9"/>',
      "folder": '<path d="M4 7a2 2 0 0 1 2-2h3.5l2 2H18a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2z"/>',
      "file": '<path d="M7 3h7l5 5v11a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z"/><path d="M14 3v5h5"/>',
      "star": '<path d="m12 4 2.4 4.9 5.4.8-3.9 3.8.9 5.4-4.8-2.5-4.8 2.5.9-5.4L4.2 9.7l5.4-.8z"/>',
      "grid": '<rect x="4" y="4" width="7" height="7" rx="1.5"/><rect x="13" y="4" width="7" height="7" rx="1.5"/><rect x="4" y="13" width="7" height="7" rx="1.5"/><rect x="13" y="13" width="7" height="7" rx="1.5"/>',
      "list": '<path d="M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01"/>',
      "settings": '<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M2 12h3M19 12h3M4.9 19.1 7 17M17 7l2.1-2.1"/>',
      "users": '<circle cx="9" cy="8" r="3.2"/><path d="M3.5 19a5.5 5.5 0 0 1 11 0"/><path d="M16 5.2a3.2 3.2 0 0 1 0 6M20.5 19a5.5 5.5 0 0 0-3.5-5.1"/>',
      "home": '<path d="M4 11 12 4l8 7"/><path d="M6 10v9a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1v-9"/>',
      "clock": '<circle cx="12" cy="12" r="8"/><path d="M12 8v4l2.5 2"/>',
      "trash": '<path d="M4 7h16M9 7V5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12"/>',
      "phone": '<path d="M6 4h3l1.5 4-2 1.5a11 11 0 0 0 5 5l1.5-2 4 1.5V18a2 2 0 0 1-2 2A14 14 0 0 1 4 6a2 2 0 0 1 2-2z"/>',
      "sparkle": '<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"/>',
      "lock": '<rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
      "bluetooth": '<path d="M7 7l10 10-5 4V3l5 4L7 17"/>',
      "wifi": '<path d="M2 9a15 15 0 0 1 20 0M5 12.5a10 10 0 0 1 14 0M8.5 16a5 5 0 0 1 7 0"/><circle cx="12" cy="19.5" r="0.6"/>'
    })
}
