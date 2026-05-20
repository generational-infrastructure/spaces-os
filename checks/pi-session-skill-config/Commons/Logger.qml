// Stub of noctalia's qs.Commons.Logger. PiSession.qml calls Logger.w("…")
// and friends; in the test harness we surface those on stderr so a real
// failure isn't hidden inside Qt's log filter.
pragma Singleton
import QtQuick

QtObject {
  function i() { console.log("[INFO]", ...arguments); }
  function w() { console.warn("[WARN]", ...arguments); }
  function e() { console.error("[ERR ]", ...arguments); }
  function d() { console.log("[DBG ]", ...arguments); }
  function l() { console.log("[LOG ]", ...arguments); }
}
