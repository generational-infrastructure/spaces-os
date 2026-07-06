// Headless host for the pure pi-event fold (Reducer.js).
//
// Reducer.js + Msg.js are staged next to this file by the driver, so
// the `.import "Msg.js"` inside Reducer.js resolves exactly as it does
// beside the production QML. No PiSession, no executor, no LLM — the
// fold is pure logic, so this check replays event streams over IPC and
// the driver asserts on the JSON that comes back.
import QtQuick
import Quickshell
import Quickshell.Io
import "Reducer.js" as Reducer

Item {
  id: root

  IpcHandler {
    target: "test:reducer"

    // Fold a whole event stream ({"events":[…]}) from Reducer.initial().
    // Deterministic clock: event i is applied at BASE + i*1000 ms, so
    // id suffixes and the tps math are reproducible. Returns
    // {"state": …, "effects": […accumulated across the replay…]}.
    function replay(streamJson: string): string {
      try {
        const events = JSON.parse(streamJson).events;
        const base = 1700000000000;
        let state = Reducer.initial();
        const effects = [];
        for (let i = 0; i < events.length; i++) {
          const r = Reducer.apply(state, events[i], base + i * 1000);
          state = r.state;
          for (const fx of r.effects) effects.push(fx);
        }
        return JSON.stringify({ state: state, effects: effects });
      } catch (e) {
        return JSON.stringify({ _error: String(e) });
      }
    }

    // Reducer.importHistory(state, piMessages, now) → state'. The args
    // ride one object ({"state":…,"piMessages":…,"now":…}).
    function importHistory(argsJson: string): string {
      try {
        const a = JSON.parse(argsJson);
        const st = a.state || Reducer.initial();
        return JSON.stringify(Reducer.importHistory(st, a.piMessages, a.now || 1700000000000));
      } catch (e) {
        return JSON.stringify({ _error: String(e) });
      }
    }
  }
}
