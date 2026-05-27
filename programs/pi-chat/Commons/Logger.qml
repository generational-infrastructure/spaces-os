// Drop-in replacement for noctalia's qs.Commons.Logger.
// PiSession/PiChatBackend/OpenUrlListener call Logger.{i,w} with
// (tag, ...args); surface those on stderr so failures are visible
// without depending on Qt's category-filter machinery.
pragma Singleton

import QtQuick

QtObject {
  function i() { console.log("[INFO]", ...arguments); }
  function w() { console.warn("[WARN]", ...arguments); }
  function e() { console.error("[ERR ]", ...arguments); }
  function d() { console.log("[DBG ]", ...arguments); }
  function l() { console.log("[LOG ]", ...arguments); }
}
