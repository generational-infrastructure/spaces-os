import { expect, test } from "bun:test";

import { SidechannelLedger } from "./sidechannel-ledger";

test("a fresh ledger is not parked", () => {
  const ledger = new SidechannelLedger();
  expect(ledger.parked).toBe(false);
  expect(ledger.pendingCount).toBe(0);
});

test("raise parks, claim relays and unparks", () => {
  const ledger = new SidechannelLedger();
  const answers: Record<string, unknown>[] = [];
  ledger.raise("ui-1", "confirm", (response) => answers.push(response));
  expect(ledger.parked).toBe(true);
  expect(ledger.pendingCount).toBe(1);

  const relay = ledger.claim("ui-1");
  expect(relay).toBeDefined();
  expect(ledger.parked).toBe(false);
  relay?.({ confirmed: true });
  expect(answers).toEqual([{ confirmed: true }]);
});

test("claim is first-answer-wins: unknown ids and lost races return nothing", () => {
  const ledger = new SidechannelLedger();
  expect(ledger.claim("never-raised")).toBeUndefined();
  ledger.raise("ui-1", "input", () => {});
  expect(ledger.claim("ui-1")).toBeDefined();
  expect(ledger.claim("ui-1")).toBeUndefined(); // second answer lost the race
});

test("the session stays parked until every open sidechannel is claimed", () => {
  const ledger = new SidechannelLedger();
  ledger.raise("ui-1", "confirm", () => {});
  ledger.raise("ui-2", "input", () => {});
  ledger.claim("ui-1");
  expect(ledger.parked).toBe(true); // ui-2 still open
  ledger.claim("ui-2");
  expect(ledger.parked).toBe(false);
});

// The missed-unpark case: the child exited with prompts still open — the
// ledger must drop every pending entry so a dead session never stays parked
// (which would wedge it un-evictable forever).
test("clear drops every pending entry and unparks", () => {
  const ledger = new SidechannelLedger();
  ledger.raise("ui-1", "confirm", () => {
    throw new Error("relay to a dead child must never fire");
  });

  ledger.clear();
  expect(ledger.parked).toBe(false);
  expect(ledger.pendingCount).toBe(0);
  expect(ledger.claim("ui-1")).toBeUndefined();
});
