// Headless host for the ModelFrecency scoring/sort/persistence test.
//
// Hosts the ModelFrecency singleton and exposes its record/sort/reload
// surface over IPC so the driver can drive ordering with injected
// timestamps (no sleep, fully deterministic). No pi, no LLM, no
// compositor.
//
// Models are passed in as a comma-separated list of "provider/id" keys
// (quickshell's ipc CLI mangles `[`/`{`, so a raw JSON array can't be an
// argument; return values are JSON and pass through fine). The sort uses
// an identity keyOf — sortModels only ever calls keyOf(entry), so a key
// string IS a valid entry, and this exercises the same code path the
// panel hits with real {provider, id} objects.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root

  function _split(csv) {
    return String(csv).length ? String(csv).split(",") : [];
  }
  function _identity(k) { return k; }

  IpcHandler {
    target: "test:frecency"

    // Record a use of `key` at the injected epoch-ms `now`.
    function record(key: string, now: string) {
      ModelFrecency.record(key, Number(now));
    }

    // Sort a comma-separated key list by frecency at `now`; return the
    // resulting keys as a JSON string.
    function order(keysCsv: string, now: string): string {
      const arr = root._split(keysCsv);
      const sorted = ModelFrecency.sortModels(arr, root._identity, Number(now));
      return JSON.stringify(sorted);
    }

    // Verify sortModels does not mutate its input: return the input
    // order before and after the sort call so the driver can compare.
    function mutationProbe(keysCsv: string, now: string): string {
      const arr = root._split(keysCsv);
      const before = arr.slice();
      ModelFrecency.sortModels(arr, root._identity, Number(now));
      return JSON.stringify({ before: before, after: arr });
    }

    // The most recently selected key (max lastUsed). The guard turns
    // a missing implementation into a recognizable assertion failure
    // instead of an opaque IPC error.
    function mostRecent(): string {
      return ModelFrecency.mostRecent ? String(ModelFrecency.mostRecent()) : "__missing__";
    }

    // The FileView reload is async, so the driver waits on loadGen()
    // bumping before asserting the post-reload ordering.
    function reload() { ModelFrecency.reload(); }
    function loadGen(): string { return String(ModelFrecency.loadGeneration); }
  }
}
