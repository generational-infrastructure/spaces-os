// Spaces Agent Sessions — plugin "service" instance.
//
// Reads the activity feed that pi-chat's PiChatBackend publishes
// (~/.local/state/spaces/pi/activity.json) and exposes it to the bar
// widget. The feed is one entry per chat:
//   { id, name, state }   state ∈ "working" | "waiting"
// plus the id of the active chat. We watch the file so the bar updates
// the moment an agent starts or finishes a turn.
pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  // Injected by the plugin host (PluginService.createObject).
  property var pluginApi: null

  // Live list of chats: [{ id, name, state }]. Empty until pi-chat
  // writes its first feed (or if pi-chat isn't running).
  property var sessions: []
  property string activeSessionId: ""

  readonly property string activityPath: {
    const home = Quickshell.env("HOME") || "";
    return home + "/.local/state/spaces/pi/activity.json";
  }

  function _apply(raw) {
    try {
      const data = JSON.parse(raw);
      root.sessions = Array.isArray(data.sessions) ? data.sessions : [];
      root.activeSessionId = data.activeSessionId || "";
    } catch (e) {
      // Partial/atomic-rewrite read: keep the previous values rather
      // than blanking the bar on a transient parse failure.
    }
  }

  FileView {
    id: activityView
    path: root.activityPath
    watchChanges: true
    printErrors: false
    onLoaded: root._apply(text())
    onFileChanged: reload()
    onLoadFailed: {
      // No feed yet (pi-chat not up, or file removed): show nothing.
      root.sessions = [];
      root.activeSessionId = "";
    }
  }

  Component.onCompleted: activityView.reload()
}
