.pragma library
// The panel↔daemon session correspondence, as a pure module. Same
// .pragma library pattern as Reducer.js, unit-checked the same way
// (checks/pi-chat-session-registry). Every documented session-list race
// the panel ever had lived in this logic — importing another client's
// sessions, claiming our own create's fresh id before the daemon's
// broadcast re-imports it, telling "deleted upstream" apart from "stale
// id the daemon never knew" — so it is concentrated here, behind one
// interface, with PiChatBackend / PiExecutor / PiSession as clients
// (the QtObject wrapper is SessionRegistry.qml).
//
// Interface (all functions pure; identity preserved on untouched
// entries so QML change signals fire only for real changes):
//
//   initial()                                    → corr
//   beginCreate(corr, sessions, requestId, panelId)      → corr
//   resolveCreate(corr, sessions, requestId, daemonId)   → { corr, sessions, panelId, changed }
//   failCreate(corr, requestId)                          → corr
//   release(sessions, panelId)                           → { sessions, changed }
//   stampDefaultExecutor(sessions, defaultId)            → { sessions, changed }
//   merge(corr, sessions, cutoff, views, makeEntry)      → { corr, sessions, cutoff,
//                                                            added, removedIds, changed }
//
// `sessions` is the panel index (PiChatBackend.sessionsList) — the
// registry reads/writes only the correspondence fields `daemonSessionId`
// and `executor`; everything else on an entry passes through untouched.
//
// `corr` is the correlation state nothing else may own:
//
//   pending   requestId → { panelId, execId }: create_sessions in
//             flight. While one is pending on an executor, merge()
//             adopts nothing new from that executor's view — a
//             created-but-unclaimed id must never re-import as a
//             foreign session. resolveCreate stamps the echoing ack's
//             daemon id onto the entry that began the create.
//
//   seen      execId → { epoch, ids }: daemon session ids observed in
//             the executor's views, per connection epoch (PiExecutor
//             bumps the epoch on every welcome). "Deleted upstream"
//             (id seen earlier THIS connection, gone from the current
//             view → drop the entry) is judged only against this — a
//             persisted id the connection never showed is NOT a
//             sibling delete and must stay for attach-bounce recovery.
//
// `views` describes the *connected* executors only:
//   [{ execId, epoch, sessions: [{ id, name, updated }] }]
// A disconnected executor is absent, and merge() withholds every
// judgment about its entries.
//
// `cutoff` (PiChatBackend.lastImportTime, persisted in sessions.json)
// gates imports: ids whose `updated` is at or below it are
// pre-existing daemon residue and stay parked; it advances to the
// highest imported `updated`, so each import only moves forward. A
// cutoff of 0 means the index has not loaded yet — merge() is a no-op.

function initial() {
  return { pending: {}, seen: {} };
}

// Record an in-flight create for the entry `panelId`. The pending
// claim's execId is the entry's pin (possibly "" for a legacy entry
// still riding the default-executor fallback — treated as "defer
// everywhere" since its executor is unknown).
function beginCreate(corr, sessions, requestId, panelId) {
  const entry = sessions.find(s => s.id === panelId);
  const pending = Object.assign({}, corr.pending);
  pending[requestId] = { panelId: panelId, execId: entry ? (entry.executor || "") : "" };
  return { pending: pending, seen: corr.seen };
}

// The daemon acked the create carrying this requestId's echo: stamp the
// assigned daemon id onto the entry that began it and drop the claim.
// Unknown requestId (no beginCreate — e.g. a session running without a
// registry) is a no-op.
function resolveCreate(corr, sessions, requestId, daemonId) {
  const p = corr.pending[requestId];
  if (!p) return { corr: corr, sessions: sessions, panelId: "", changed: false };
  const pending = Object.assign({}, corr.pending);
  delete pending[requestId];
  const next = { pending: pending, seen: corr.seen };
  let changed = false;
  const out = sessions.map(s => {
    if (s.id !== p.panelId || s.daemonSessionId === daemonId) return s;
    changed = true;
    return Object.assign({}, s, { daemonSessionId: daemonId });
  });
  return { corr: next, sessions: changed ? out : sessions, panelId: p.panelId, changed: changed };
}

// The create failed (error ack, or the connection dropped mid-create):
// drop the claim so deferred imports land on the next merge.
function failCreate(corr, requestId) {
  if (!corr.pending[requestId]) return corr;
  const pending = Object.assign({}, corr.pending);
  delete pending[requestId];
  return { pending: pending, seen: corr.seen };
}

// Clear an entry's daemon binding (restart drops the old daemon
// session; stale recovery drops an id the daemon lost) so a panel
// restart doesn't chase the dead id.
function release(sessions, panelId) {
  let changed = false;
  const out = sessions.map(s => {
    if (s.id !== panelId || !s.daemonSessionId) return s;
    changed = true;
    return Object.assign({}, s, { daemonSessionId: "" });
  });
  return { sessions: changed ? out : sessions, changed: changed };
}

// Pin executor:"" legacies (entries minted before the config loaded)
// to the default executor once it is known: a later defaultExecutor
// config change must not silently migrate an existing chat — its
// daemonSessionId only exists on the executor that minted it.
function stampDefaultExecutor(sessions, defaultId) {
  if (!defaultId) return { sessions: sessions, changed: false };
  let changed = false;
  const out = sessions.map(s => {
    if (s.executor) return s;
    changed = true;
    return Object.assign({}, s, { executor: defaultId });
  });
  return { sessions: changed ? out : sessions, changed: changed };
}

// Merge every connected executor's session-list view into the index:
//
//   removals  an entry whose daemon id this connection observed earlier
//             and which is gone from the executor's current view was
//             deleted upstream (a sibling's delete_session) — drop it.
//   adds      unknown ids past the cutoff import as new entries (built
//             by makeEntry(daemonId, name, execId); daemonSessionId is
//             stamped here so the contract holds regardless of the
//             callback), unless a create is pending on that executor —
//             then the whole view's adoption defers to the next merge,
//             which the daemon's post-ack broadcast guarantees.
function merge(corr, sessions, cutoff, views, makeEntry) {
  const noop = {
    corr: corr, sessions: sessions, cutoff: cutoff,
    added: [], removedIds: [], changed: false,
  };
  if (!(cutoff > 0)) return noop; // index not loaded yet

  // Fold the current views into the per-epoch observation sets.
  const seen = Object.assign({}, corr.seen);
  const byExec = {};
  for (const view of views) {
    const prev = seen[view.execId];
    const ids = (prev && prev.epoch === view.epoch) ? Object.assign({}, prev.ids) : {};
    const current = new Set();
    for (const r of view.sessions || []) {
      if (!r || !r.id) continue;
      ids[r.id] = true;
      current.add(r.id);
    }
    seen[view.execId] = { epoch: view.epoch, ids: ids };
    byExec[view.execId] = { view: view, current: current };
  }
  const corrOut = { pending: corr.pending, seen: seen };

  // Executors with a create in flight; "" = entry executor unknown,
  // defer adoption everywhere.
  const pendingExecs = new Set();
  for (const rid in corr.pending) pendingExecs.add(corr.pending[rid].execId);
  const deferAll = pendingExecs.has("");

  const known = new Set();
  for (const s of sessions) {
    if (s.daemonSessionId) known.add(s.daemonSessionId);
  }

  const removedIds = [];
  for (const s of sessions) {
    if (!s.daemonSessionId || !s.executor) continue;
    const slot = byExec[s.executor];
    if (!slot) continue; // executor offline → withhold judgment
    if (slot.current.has(s.daemonSessionId)) continue;
    if (!seen[s.executor].ids[s.daemonSessionId]) continue;
    removedIds.push(s.id);
  }

  const added = [];
  let newCutoff = cutoff;
  for (const view of views) {
    if (deferAll || pendingExecs.has(view.execId)) continue;
    for (const r of view.sessions || []) {
      if (!r || !r.id || known.has(r.id)) continue;
      const updated = r.updated || 0;
      if (updated <= cutoff) continue;
      known.add(r.id);
      const entry = makeEntry(r.id, r.name || "", view.execId);
      entry.daemonSessionId = r.id;
      added.push(entry);
      if (updated > newCutoff) newCutoff = updated;
    }
  }

  if (removedIds.length === 0 && added.length === 0) {
    return {
      corr: corrOut, sessions: sessions, cutoff: cutoff,
      added: [], removedIds: [], changed: false,
    };
  }
  const removeSet = new Set(removedIds);
  let out = sessions.filter(s => !removeSet.has(s.id));
  if (added.length > 0) out = out.concat(added);
  return {
    corr: corrOut,
    sessions: out,
    cutoff: added.length > 0 ? newCutoff : cutoff,
    added: added,
    removedIds: removedIds,
    changed: true,
  };
}
