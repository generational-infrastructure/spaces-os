// RpcDriver drives a headless pi child over the JSON-line pipe. These tests
// run it against a stub child (rpc-driver.fixture.ts) so the real transport —
// id correlation, the event stream, and the extension_ui side-channel — is
// exercised without a model or network. Waits block on the actual frame the
// assertion needs (rule: no wall-clock timers in tests).
import { expect, test } from "bun:test";
import { join } from "node:path";
import { RpcDriver, type RpcFrame } from "./rpc-driver";

const FIXTURE = join(import.meta.dir, "rpc-driver.fixture.ts");

interface Waiter {
  pred: (frame: RpcFrame) => boolean;
  resolve: (frame: RpcFrame) => void;
}

// A driver plus promise-based awaiters over each stream, so a test blocks on
// the precise frame it expects rather than a guessed delay.
function harness() {
  const events: RpcFrame[] = [];
  const ui: RpcFrame[] = [];
  const eventWaiters: Waiter[] = [];
  const uiWaiters: Waiter[] = [];

  const record = (
    store: RpcFrame[],
    waiters: Waiter[],
    frame: RpcFrame,
  ): void => {
    store.push(frame);
    for (let i = waiters.length - 1; i >= 0; i--) {
      if (waiters[i].pred(frame)) {
        waiters[i].resolve(frame);
        waiters.splice(i, 1);
      }
    }
  };

  const waitFor = (
    store: RpcFrame[],
    waiters: Waiter[],
    pred: (frame: RpcFrame) => boolean,
  ): Promise<RpcFrame> => {
    const already = store.find(pred);
    if (already) return Promise.resolve(already);
    const { promise, resolve } = Promise.withResolvers<RpcFrame>();
    waiters.push({ pred, resolve });
    return promise;
  };

  const driver = new RpcDriver({
    argv: ["bun", FIXTURE],
    onEvent: (f) => record(events, eventWaiters, f),
    onExtensionUI: (f) => record(ui, uiWaiters, f),
  });

  return {
    driver,
    events,
    ui,
    waitEvent: (pred: (frame: RpcFrame) => boolean) =>
      waitFor(events, eventWaiters, pred),
    waitUI: (pred: (frame: RpcFrame) => boolean) =>
      waitFor(ui, uiWaiters, pred),
  };
}

test("request correlates a response to its command by id", async () => {
  const h = harness();
  const resp = await h.driver.request({ type: "get_state" });
  expect(resp.success).toBe(true);
  expect((resp.data as { model: { id: string } }).model.id).toBe("m1");
  await h.driver.stop();
});

test("session events stream to onEvent, never the side channel", async () => {
  const h = harness();
  await h.driver.request({ type: "prompt", message: "hi" });
  await h.waitEvent((f) => f.type === "agent_end");
  expect(h.events.map((e) => e.type)).toContain("agent_start");
  expect(h.ui).toHaveLength(0);
  await h.driver.stop();
});

test("extension_ui request surfaces and its response round-trips to the child", async () => {
  const h = harness();
  await h.driver.request({ type: "prompt", message: "ask" });
  const req = await h.waitUI((f) => f.method === "confirm");
  expect(req.title).toBe("t");
  // The supervisor relays the panel's answer back over the same pipe.
  h.driver.send({
    type: "extension_ui_response",
    id: req.id as string,
    confirmed: true,
  });
  const confirmed = await h.waitEvent((f) => f.type === "confirmed");
  expect(confirmed.value).toBe(true);
  await h.driver.stop();
});
