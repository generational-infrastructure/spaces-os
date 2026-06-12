// Headless host for the model-picker contract.
//
// Mounts the real PiChatBackend plus the REAL NComboBox widget, bound
// exactly the way Panel.qml's header model selector binds it (model
// list from chat.models via ModelFrecency, currentKey from
// chat.activeModel). The point of this check is the layer the data-only
// probes skip: what the combobox actually DISPLAYS. A regression where
// session.models fills but the closed combobox stays blank (no current
// item) is invisible to sessionModel()-style assertions and was exactly
// the bug observed in the GUI VM — so the driver asserts displayText,
// count, and currentIndex on this combobox, not just the session state.
//
// Keep the bindings below in sync with Panel.qml (NComboBox in the
// header RowLayout); they are intentionally a verbatim mirror.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Widgets

Item {
  id: root

  PiChatBackend {
    id: backend
    // The picker lives in the open panel; visibility itself is not part
    // of this contract (no reaper interplay — idle timeout is far away).
    panelVisible: true
  }

  // ── verbatim mirror of Panel.qml's model selector ──
  NComboBox {
    id: modelCombo
    model: ModelFrecency.sortModels(backend.chat?.models ?? [], m => m.provider + "/" + m.id).map(m => ({
      key: m.provider + "/" + m.id,
      name: "[" + (m.provider === "local" ? (backend.chat?.executor?.executorId || "local") : m.provider) + "] " + m.id + (m.reasoning ? "  ⚡" : ""),
      provider: m.provider,
      modelId: m.id,
    }))
    currentKey: backend.chat?.activeModel ?? ""
    onSelected: key => {
      const item = (backend.chat?.models ?? []).find(m => (m.provider + "/" + m.id) === key);
      if (item) backend.chat.setModel(item.provider, item.id);
    }
  }

  IpcHandler {
    target: "test:model-picker"

    function ping(): bool { return true; }

    // What Panel.onCompleted does when the panel opens: ask the active
    // session for its model list (spawning/attaching it on demand).
    function openPanel() { backend.chat?.listModels(); }

    // ── data layer (session state) ──
    function modelsCount(): int { return (backend.chat?.models ?? []).length; }
    function activeModel(): string { return backend.chat?.activeModel ?? ""; }

    // ── presentation layer (what the user sees) ──
    function comboCount(): int { return modelCombo.count; }
    function comboDisplayText(): string { return modelCombo.displayText; }
    function comboCurrentIndex(): int { return modelCombo.currentIndex; }

    // Index introspection for the persisted-entry scenario.
    function rawSessions(): string {
      return JSON.stringify(backend.sessionsList.map(s => ({
        id: s.id,
        executor: s.executor,
        daemonSessionId: s.daemonSessionId || "",
      })));
    }

    // Diagnostic: the raw adapter view next to the backend's list —
    // tells load-vs-clobber stories apart when the index goes missing.
    function debugState(): string {
      return JSON.stringify({
        adapterSessions: backend._sessions.sessions,
        adapterActive: backend._sessions.activeSessionId,
        adapterImportTime: backend._sessions.lastImportTime,
        backendImportTime: backend.lastImportTime,
      });
    }
  }
}
