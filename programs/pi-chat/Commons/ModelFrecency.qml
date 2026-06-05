// Model frecency: orders the chat model lists by how often *and* how
// recently each model was picked, so a user's working set floats to the
// top of every selector instead of sitting in backend/insertion order.
//
// Algorithm — a single exponentially-decaying score per model, the
// zoxide/z "frecency" trick. Each use adds 1 to the model's score after
// the old score has been decayed toward the present; sorting decays once
// more to the moment of comparison. One number captures both axes: many
// uses pile the score up (frequency), and the decay means an old pile
// melts unless it's refreshed (recency).
//
// HALF_LIFE is 3 days. The score halves every 3 days of disuse, which is
// the knob that makes "most recently used floats to the top" actually
// hold: long enough that a model picked several times this week stays
// near the top through a quiet day, short enough that a single pick
// yesterday yields to today's choice (after one half-life a lone older
// pick has decayed to 0.5, below a fresh +1). Among models of similar
// age the raw count still decides, so repeat favourites outrank one-offs.
//
// This is generated *state*, not user config, so it lives next to
// sessions.json under $HOME/.local/state/spaces/pi (mirroring
// PiChatBackend's stateDir), persisted via its own FileView+JsonAdapter.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
  id: root

  // 3 days in ms. See the file header for why 3 days specifically.
  readonly property double halfLife: 259200000

  // State dir mirrors PiChatBackend.qml: $HOME/.local/state/spaces/pi.
  readonly property string stateDir:
    String(Quickshell.env("HOME")) + "/.local/state/spaces/pi"

  // Bumped on every completed (re)load so headless tests can wait for an
  // async reload() to land before asserting on the reloaded store.
  property int loadGeneration: 0

  function _store() { return _adapter.models || ({}); }

  // 0.5 ** (elapsed / halfLife) — the decay factor for `elapsed` ms.
  function _decay(elapsed) {
    return Math.pow(0.5, elapsed / root.halfLife);
  }

  // Score a model as of `now`, decaying its stored score from lastUsed.
  // Unknown keys score 0. Used only for sorting.
  function effectiveScore(key, now) {
    if (now === undefined) now = Date.now();
    const e = _store()[key];
    if (!e) return 0;
    return e.score * root._decay(now - e.lastUsed);
  }

  // Record a use of `key` at `now`: decay the old score to the present,
  // add 1, stamp lastUsed, persist.
  function record(key, now) {
    if (now === undefined) now = Date.now();
    const store = _store();
    const prev = store[key];
    const decayed = prev ? prev.score * root._decay(now - prev.lastUsed) : 0;
    // Reassign the whole map: JsonAdapter only notices a new value on the
    // `var` property, not an in-place mutation of the held object.
    const next = {};
    for (const k in store) next[k] = store[k];
    next[key] = { score: decayed + 1, lastUsed: now };
    _adapter.models = next;
    root.persist();
  }

  // Return a NEW array of `models` ordered by frecency as of `now`,
  // without mutating the input. `keyOf(entry)` -> the "provider/id" key.
  // Used models (effectiveScore > 0) come first, by score desc, then
  // lastUsed desc, then key asc (fully deterministic). Never-used models
  // follow in their original input order (stable tail). Decorate-sort-
  // undecorate keeps that tail order exactly as given.
  function sortModels(models, keyOf, now) {
    if (now === undefined) now = Date.now();
    const arr = Array.isArray(models) ? models : [];
    const store = root._store();
    const decorated = arr.map((entry, i) => {
      const key = keyOf(entry);
      const e = store[key];
      const score = e ? e.score * root._decay(now - e.lastUsed) : 0;
      return {
        entry: entry,
        index: i,
        score: score,
        lastUsed: e ? e.lastUsed : 0,
        key: key,
      };
    });
    const used = decorated.filter(d => d.score > 0);
    const unused = decorated.filter(d => d.score <= 0);
    used.sort((a, b) => {
      if (b.score !== a.score) return b.score - a.score;
      if (b.lastUsed !== a.lastUsed) return b.lastUsed - a.lastUsed;
      return a.key < b.key ? -1 : (a.key > b.key ? 1 : 0);
    });
    unused.sort((a, b) => a.index - b.index);
    return used.concat(unused).map(d => d.entry);
  }

  function persist() { _file.writeAdapter(); }

  // Force a re-read of the store from disk. Async; completion bumps
  // loadGeneration via onLoaded.
  function reload() { _file.reload(); }

  property FileView _file: FileView {
    path: root.stateDir + "/model-frecency.json"
    printErrors: false
    // Versioned wrapper: { version: 1, models: { "<provider>/<id>":
    // { score, lastUsed } } }. version is a forward-compat seam.
    JsonAdapter {
      id: _adapter
      property int version: 1
      property var models: ({})
    }
    onLoaded: root.loadGeneration += 1
    onLoadFailed: () => {
      // First launch: no state yet. Write empty defaults so the file
      // exists and later records persist cleanly.
      writeAdapter();
    }
    // FileView 0.3.0 does not read on construction (setPath only arms the
    // watcher); prime it once so the store loads immediately.
    Component.onCompleted: reload()
  }
}
