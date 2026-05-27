// Image-attach file picker.
//
// Replaces noctalia's 800-line custom popup with Qt's native
// FileDialog (via `QtCore.StandardPaths` for the initial location
// and the platform file chooser portal where available). The chat
// panel's only call site is:
//
//   NFilePicker {
//     title: ...
//     selectionMode: "files"
//     nameFilters: ["*.png", "*.jpg", ...]
//     initialPath: ...
//     onAccepted: paths => chat.sendFile(paths[0])
//   }
//   filePicker.openFilePicker()
//
// We expose the same API surface so the port is a verbatim import
// swap. `nameFilters` is rewritten from noctalia's bare-glob list
// (`["*.png", "*.jpg"]`) to Qt's labelled form (`["Images (*.png
// *.jpg)"]`) inline.
import QtQuick
import QtQuick.Dialogs

QtObject {
  id: root

  property string title: ""
  property string initialPath: ""
  property string selectionMode: "files"  // "files" or "folders"
  property var nameFilters: ["*"]
  property bool showHiddenFiles: false
  property bool allowMultiSelection: false

  signal accepted(var paths)
  signal cancelled

  function openFilePicker() {
    _dialog.open();
  }
  Component.onCompleted: _syncTitle()
  onTitleChanged: _syncTitle()
  function _syncTitle() { if (_dialog) _dialog.title = title; }

  property FileDialog _dialog: FileDialog {
    // FileDialog ships a `title` property of its own. Aliasing
    // root.title straight onto it produces a Qt binding loop
    // diagnostic (the inner emits its own change signal, the outer
    // reflects it back). Push the title imperatively on
    // construction and whenever the wrapper's title changes —
    // observable behaviour is identical, no loop.
    fileMode: root.allowMultiSelection ? FileDialog.OpenFiles : FileDialog.OpenFile
    currentFolder: root.initialPath ? ("file://" + root.initialPath) : ""
    // Tabler-style globs → Qt labelled form. We render every entry
    // as a single combined filter ("Images (*.png *.jpg)") so the
    // chooser doesn't show one entry per pattern.
    nameFilters: [(root.nameFilters || []).join(" ").length > 0
                  ? "Files (" + (root.nameFilters || ["*"]).join(" ") + ")"
                  : "All files (*)"]
    onAccepted: {
      const paths = root.allowMultiSelection
        ? selectedFiles.map(u => String(u).replace(/^file:\/\//, ""))
        : [String(selectedFile).replace(/^file:\/\//, "")];
      root.accepted(paths);
    }
    onRejected: root.cancelled()
  }
}
