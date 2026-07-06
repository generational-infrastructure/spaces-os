// Headless host for the pure panel↔daemon session registry
// (SessionRegistry.js), staged next to this file by the driver.
//
// Each scenario is a table of ops folded through the registry
// interface from a blank correspondence state; the driver asserts on
// the JSON that comes back: final index entries, cutoff, and the
// per-op trace (what each merge added/removed, what each claim
// stamped).
import QtQuick
import Quickshell
import Quickshell.Io
import "SessionRegistry.js" as Registry

Item {
  id: root

  IpcHandler {
    target: "test:registry"

    // Fold one scenario ({"ops":[…]}). Entries minted for imported
    // daemon sessions use the same panel-id-equals-daemon-id shape
    // PiChatBackend's makeEntry produces, minus the display-only
    // fields the correspondence never reads.
    function run(scenarioJson: string): string {
      try {
        const sc = JSON.parse(scenarioJson);
        let corr = Registry.initial();
        let sessions = [];
        let cutoff = 0;
        const trace = [];
        const makeEntry = (daemonId, name, execId) => ({
          id: daemonId,
          name: name || (execId + ":" + daemonId),
          executor: execId,
          daemonSessionId: daemonId,
        });
        for (const op of sc.ops) {
          if (op.op === "load") {
            sessions = op.sessions || [];
            cutoff = op.cutoff || 0;
            trace.push({ op: "load" });
          } else if (op.op === "beginCreate") {
            corr = Registry.beginCreate(corr, sessions, op.requestId, op.panelId);
            trace.push({ op: "beginCreate" });
          } else if (op.op === "resolveCreate") {
            const r = Registry.resolveCreate(corr, sessions, op.requestId, op.daemonId);
            corr = r.corr;
            sessions = r.sessions;
            trace.push({ op: "resolveCreate", panelId: r.panelId, changed: r.changed });
          } else if (op.op === "failCreate") {
            corr = Registry.failCreate(corr, op.requestId);
            trace.push({ op: "failCreate" });
          } else if (op.op === "release") {
            const r = Registry.release(sessions, op.panelId);
            sessions = r.sessions;
            trace.push({ op: "release", changed: r.changed });
          } else if (op.op === "stampDefault") {
            const r = Registry.stampDefaultExecutor(sessions, op.executor);
            sessions = r.sessions;
            trace.push({ op: "stampDefault", changed: r.changed });
          } else if (op.op === "merge") {
            const r = Registry.merge(corr, sessions, cutoff, op.views || [], makeEntry);
            corr = r.corr;
            sessions = r.sessions;
            cutoff = r.cutoff;
            trace.push({
              op: "merge",
              added: r.added.map(e => e.id),
              removedIds: r.removedIds,
              changed: r.changed,
            });
          } else {
            throw new Error("unknown op " + op.op);
          }
        }
        return JSON.stringify({ sessions: sessions, lastImportTime: cutoff, trace: trace });
      } catch (e) {
        return JSON.stringify({ _error: String(e) });
      }
    }
  }
}
