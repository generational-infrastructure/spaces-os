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

test("an approval parks until its verdict settles the promise", async () => {
  const ledger = new SidechannelLedger();
  const verdict = ledger.raiseApproval("appr-1");
  expect(ledger.parked).toBe(true);
  expect(ledger.settleApproval("appr-1", "session")).toBe(true);
  expect(ledger.parked).toBe(false);
  expect(await verdict).toBe("session");
});

test("settling an unknown approval is a no-op", () => {
  const ledger = new SidechannelLedger();
  ledger.raise("ui-1", "confirm", () => {});
  expect(ledger.settleApproval("ghost", "deny")).toBe(false);
  expect(ledger.parked).toBe(true); // untouched
});

// The spurious-unpark case: answering the last sidechannel while an approval
// is still open must NOT unpark (main.ts used to re-derive parked from the
// sidechannel map alone here).
test("resolving the last sidechannel keeps the session parked on an open approval", () => {
  const ledger = new SidechannelLedger();
  ledger.raise("ui-1", "confirm", () => {});
  void ledger.raiseApproval("appr-1");

  ledger.claim("ui-1");
  expect(ledger.parked).toBe(true); // approval still open

  ledger.settleApproval("appr-1", "once");
  expect(ledger.parked).toBe(false);
});

test("settling the last approval keeps the session parked on an open sidechannel", () => {
  const ledger = new SidechannelLedger();
  void ledger.raiseApproval("appr-1");
  ledger.raise("ui-1", "confirm", () => {});

  ledger.settleApproval("appr-1", "deny");
  expect(ledger.parked).toBe(true); // sidechannel still open

  ledger.claim("ui-1");
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
  void ledger.raiseApproval("appr-1");

  ledger.clear();
  expect(ledger.parked).toBe(false);
  expect(ledger.pendingCount).toBe(0);
  expect(ledger.claim("ui-1")).toBeUndefined();
  expect(ledger.settleApproval("appr-1", "once")).toBe(false);
});
