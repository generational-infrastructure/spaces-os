pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

import qs.Commons

// Manage plugins discovered under `~/.config/noctalia/plugins-autoload/`.
//
// Owns the full lifecycle:
//   - Auto-enable plugins newly appearing in the autoload dir.
//   - Tag autoload-owned entries in plugins.json with `autoload: true`.
//   - GC autoload entries whose on-disk manifest has been removed (e.g.
//     when a distro generation drops a plugin). Without this noctalia
//     keeps the enabled flag in plugins.json, fails to find the manifest
//     at startup, and tries to download from its plugin marketplace —
//     surfacing as a "Failed to install: download failed" toast on every
//     login.
//
// Invoked from two minimal hook points in upstream code:
//   1. PluginRegistry.scanPluginFolder() — instead of emitting
//      `pluginsChanged()` directly, the patch hands the emit to us so
//      we can synchronously GC stale entries before PluginService.init()
//      observes them (and would otherwise launch ghost downloads).
//   2. PluginService._onPluginLoadComplete() — after all enabled plugins
//      finish loading, we add bar widgets for newly autoloaded ones.
Singleton {
  id: root

  readonly property string autoloadDir: Settings.configDir + "plugins-autoload"

  // Plugin IDs autoloaded during this session (cleared after widgets are added).
  property var pendingAutoloads: ({})

  // One-time migration: plugin IDs that were autoloaded by older distro
  // generations but never got the `autoload: true` flag. Treat them as
  // ours so the GC step drops them when their manifest is missing. New
  // entries we register here already carry the flag and don't need to
  // be listed.
  readonly property var legacyAutoloadIds: ({
    "opencrow-skill-config": true,
  })

  // Plugin IDs already known from plugins.json before this session started.
  // The regular plugin scan adds entries to pluginStates with enabled:false,
  // so we need a snapshot from BEFORE that to know what's actually new.
  property var initialKnownPlugins: ({})

  Component.onCompleted: {
    // Read plugins.json to capture user state before noctalia adds scan entries.
    var snap = Qt.createQmlObject(`
      import QtQuick
      import Quickshell.Io
      Process {
        command: ["sh", "-c", "cat '${PluginRegistry.pluginsFile}' 2>/dev/null || echo '{}'"]
        stdout: StdioCollector {}
        running: true
      }
    `, root, "AutoloadSnapshot");
    snap.exited.connect(function () {
      try {
        var data = JSON.parse(String(snap.stdout.text || "{}"));
        var states = data.states || {};
        for (var k in states) {
          root.initialKnownPlugins[k] = true;
        }
      } catch (e) {
        Logger.w("PluginAutoload", "Failed to snapshot plugins.json:", e.toString());
      }
      snap.destroy();
    });
  }

  // Scan the autoload dir, GC stale autoload-owned entries, and register
  // new ones. Invokes `done` after the in-memory pluginStates is settled
  // so the caller can fire pluginsChanged with the cleaned-up view.
  function processAutoloadDir(done) {
    Logger.i("PluginAutoload", "Scanning autoload dir:", root.autoloadDir);
    var scan = Qt.createQmlObject(`
      import QtQuick
      import Quickshell.Io
      Process {
        command: ["sh", "-c", "for d in '${root.autoloadDir}'/*/; do [ -d \\"$d\\" ] || continue; [ -f \\"$d/manifest.json\\" ] || continue; basename \\"$d\\"; done"]
        stdout: StdioCollector {}
        running: true
      }
    `, root, "AutoloadScan");

    scan.exited.connect(function (exitCode) {
      var ids = String(scan.stdout.text || "").trim().split("\n").filter(function (s) {
        return s.length > 0;
      });
      var live = ({});
      for (var i = 0; i < ids.length; i++) live[ids[i]] = true;

      var changed = false;
      var states = PluginRegistry.pluginStates;

      // GC: drop autoload-owned entries whose manifest is no longer on
      // disk. Two flavours:
      //   - `autoload: true` was written by an earlier run of this code.
      //   - legacyAutoloadIds covers ids registered by older generations
      //     that predate the autoload flag.
      var toDrop = [];
      for (var sid in states) {
        if (live[sid]) continue;
        var owned = (states[sid] && states[sid].autoload === true)
                    || root.legacyAutoloadIds[sid] === true;
        if (owned) toDrop.push(sid);
      }
      for (var j = 0; j < toDrop.length; j++) {
        Logger.i("PluginAutoload", "Garbage-collecting stale autoload plugin:", toDrop[j]);
        delete states[toDrop[j]];
        delete root.initialKnownPlugins[toDrop[j]];
        changed = true;
      }

      // Backfill the `autoload: true` flag on plugins currently in the
      // autoload dir so future GC owns them too. Auto-enable newly
      // discovered ones (initialKnownPlugins captured the pre-scan view).
      for (var k = 0; k < ids.length; k++) {
        var pid = ids[k];
        if (!root.initialKnownPlugins[pid]) {
          states[pid] = { enabled: true, autoload: true };
          root.pendingAutoloads[pid] = { barSection: "center" };
          Logger.i("PluginAutoload", "Auto-enabled plugin:", pid);
          changed = true;
        } else if (!states[pid] || states[pid].autoload !== true) {
          states[pid] = Object.assign({}, states[pid] || { enabled: true }, { autoload: true });
          changed = true;
        }
      }

      if (changed) {
        // Reassign so PluginRegistry's property change notifier fires;
        // mutating the existing object in place doesn't.
        PluginRegistry.pluginStates = states;

        // Persist plugins.json directly via shell. PluginRegistry.save()
        // goes through FileView.writeAdapter(), which can silently no-op
        // when the initial load failed before ensurePluginsFile created
        // the file.
        var json = JSON.stringify({
          version: PluginRegistry.currentVersion,
          states: PluginRegistry.pluginStates,
          sources: PluginRegistry.pluginSources || []
        });
        var path = PluginRegistry.pluginsFile;
        // Pass JSON via base64 to dodge any shell-quoting ambiguity.
        var b64 = Qt.btoa(json);
        var write = Qt.createQmlObject(
          'import QtQuick; import Quickshell.Io; '
          + 'Process { stdout: StdioCollector {} }',
          root, "AutoloadWrite");
        write.command = ["sh", "-c", "echo '" + b64 + "' | base64 -d > '" + path + "'"];
        write.running = true;
      }
      scan.destroy();
      if (typeof done === "function") done();
    });
  }

  // Called from PluginService once all enabled plugins finished loading.
  // Adds bar widgets for plugins that were autoloaded in this session.
  function addAutoloadedWidgets() {
    for (var pid in root.pendingAutoloads) {
      var manifest = PluginRegistry.getPluginManifest(pid);
      if (manifest && manifest.entryPoints && manifest.entryPoints.barWidget) {
        var widgetId = "plugin:" + pid;
        var section = root.pendingAutoloads[pid].barSection || "right";
        PluginService.addWidgetToBar(widgetId, section);
        Logger.i("PluginAutoload", "Added autoloaded bar widget:", widgetId, "to", section);
      }
    }
    root.pendingAutoloads = ({});
  }
}
