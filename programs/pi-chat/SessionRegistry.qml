// Thin stateful wrapper around the pure correspondence fold
// (SessionRegistry.js): holds the panel index (`sessions` — aliased as
// PiChatBackend.sessionsList), the import cutoff, and the correlation
// state (pending creates, per-connection observation sets), applying
// each fold result back. PiChatBackend, PiExecutor and PiSession are
// clients — nothing outside this module touches daemonSessionId
// stamps, import cutoffs, or upstream-removal judgments.
import QtQuick
import "SessionRegistry.js" as Impl

QtObject {
  id: reg

  // The panel index entries. The owner (PiChatBackend) stays the writer
  // for display fields (name, unread, lastActiveAt, …) through its
  // sessionsList alias and seeds both properties from sessions.json;
  // the registry is the only writer of the correspondence itself
  // (daemonSessionId stamps, imports, upstream removals, executor
  // pins).
  property var sessions: []
  // Import cutoff (ms since epoch), persisted in sessions.json. At or
  // below 0 the index has not loaded yet — merges are no-ops.
  property double lastImportTime: 0
  property var _corr: Impl.initial()

  // Record an in-flight create_session (requestId minted by
  // PiExecutor.createSession) for the entry `panelId`. Until it
  // resolves or fails, merge() adopts nothing new from that entry's
  // executor.
  function beginCreate(requestId, panelId) {
    _corr = Impl.beginCreate(_corr, sessions, requestId, panelId);
  }

  // The correlated create ack arrived: stamp its daemon id onto the
  // entry that began the create. Returns true when an entry changed
  // (the caller persists).
  function resolveCreate(requestId, daemonId) {
    const r = Impl.resolveCreate(_corr, sessions, requestId, daemonId);
    _corr = r.corr;
    if (r.changed) sessions = r.sessions;
    return r.changed;
  }

  function failCreate(requestId) {
    _corr = Impl.failCreate(_corr, requestId);
  }

  // Clear an entry's daemon binding (restart / stale recovery). Returns
  // true when the entry changed (the caller persists).
  function release(panelId) {
    const r = Impl.release(sessions, panelId);
    if (r.changed) sessions = r.sessions;
    return r.changed;
  }

  // Pin executor:"" legacies to the default executor. Returns true when
  // an entry changed (the caller persists).
  function stampDefaultExecutor(defaultId) {
    const r = Impl.stampDefaultExecutor(sessions, defaultId);
    if (r.changed) sessions = r.sessions;
    return r.changed;
  }

  // Merge the connected executors' views (see SessionRegistry.js for
  // the views shape and the cutoff/pending/seen semantics). Returns
  // { added, removedIds, changed } for the owner's side effects
  // (workspace dirs, active-session fixup, persistence).
  function merge(views, makeEntry) {
    const r = Impl.merge(_corr, sessions, lastImportTime, views, makeEntry);
    _corr = r.corr;
    if (r.changed) {
      sessions = r.sessions;
      lastImportTime = r.cutoff;
    }
    return { added: r.added, removedIds: r.removedIds, changed: r.changed };
  }
}
