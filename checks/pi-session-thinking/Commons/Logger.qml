pragma Singleton
import QtQuick

QtObject {
  function w(...args) { console.warn(...args); }
  function i(...args) { console.info(...args); }
}
