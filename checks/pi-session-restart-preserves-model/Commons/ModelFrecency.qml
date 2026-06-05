// Test stub: PiSession.qml calls ModelFrecency.record() on every model
// selection, but this check is about restart() re-asserting set_model,
// not about frecency. A no-op record() satisfies the dependency without
// dragging in the real singleton's FileView/JsonAdapter disk persistence,
// keeping the test hermetic and decoupled from frecency internals.
pragma Singleton
import QtQuick

QtObject {
  function record(key, now) {}
}
