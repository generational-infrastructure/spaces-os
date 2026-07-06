// Shared-corpus replay: fold the canonical pi event streams from
// checks/pi-chat-reducer/fixtures (the same files the quickshell
// panel's Reducer.js replays) through the PWA reducer and assert the
// renderer-agnostic projection both folds must agree on:
//
//   transcript — plain chat text as (role, text, streaming), in order
//   confirms   — confirm cards as (id, state)
//
// Chat-panel-only expectations (expect.chat: thinking bubbles, tool
// notices, tps patches, effects) are ignored here; the QML side pins
// those. A divergence between the two folds turns this file or
// checks/pi-chat-reducer red. Fixture dir comes in via
// $PI_EVENT_FIXTURES (wired by default.nix).
import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

import { emptyState, withPiEvent } from "./reducer";

const dir = process.env.PI_EVENT_FIXTURES;
if (!dir) throw new Error("PI_EVENT_FIXTURES is not set");

interface Fixture {
  events: unknown[];
  expect: {
    transcript: { role: string; text: string; streaming: boolean }[];
    confirms?: { id: string; state: string }[];
  };
}

const names = readdirSync(dir)
  .filter((f) => f.endsWith(".json"))
  .sort();
if (names.length === 0) throw new Error(`no fixtures under ${dir}`);

for (const name of names) {
  const fx = JSON.parse(readFileSync(join(dir, name), "utf8")) as Fixture;
  test(`corpus: ${name}`, () => {
    let s = emptyState();
    for (const ev of fx.events) s = withPiEvent(s, ev);
    const transcript = s.messages.map((m) => ({
      role: m.role,
      text: m.text,
      streaming: m.streaming,
    }));
    expect(transcript).toEqual(fx.expect.transcript);
    const confirms = s.confirms.map((c) => ({ id: c.id, state: c.state }));
    expect(confirms).toEqual(fx.expect.confirms ?? []);
  });
}
