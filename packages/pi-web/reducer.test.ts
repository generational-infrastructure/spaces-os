import { expect, test } from "bun:test";

import {
  emptyState,
  withConfirmAnswer,
  withPiEvent,
  withSidechannelResolved,
  withUserPrompt,
} from "./reducer";

function delta(d: string) {
  return {
    type: "message_update",
    assistantMessageEvent: { type: "text_delta", delta: d },
  };
}

test("a user prompt is appended verbatim", () => {
  const s = withUserPrompt(emptyState(), "hello");
  expect(s.messages).toEqual([
    { role: "user", text: "hello", streaming: false },
  ]);
});

test("a streamed reply accumulates deltas into one assistant bubble", () => {
  let s = emptyState();
  s = withPiEvent(s, { type: "agent_start" });
  expect(s.typing).toBe(true);
  s = withPiEvent(s, {
    type: "message_update",
    assistantMessageEvent: { type: "text_start" },
  });
  for (const d of ["Hello", ", ", "world", "!"]) s = withPiEvent(s, delta(d));
  s = withPiEvent(s, { type: "agent_end" });

  expect(s.typing).toBe(false);
  expect(s.messages).toHaveLength(1);
  expect(s.messages[0]).toEqual({
    role: "assistant",
    text: "Hello, world!",
    streaming: false,
  });
});

test("text_delta without a text_start still opens one streaming bubble", () => {
  let s = withPiEvent(emptyState(), delta("a"));
  s = withPiEvent(s, delta("b"));
  expect(s.messages).toEqual([
    { role: "assistant", text: "ab", streaming: true },
  ]);
});

test("text_end overrides the accumulated text with the final content", () => {
  let s = withPiEvent(emptyState(), delta("partial"));
  s = withPiEvent(s, {
    type: "message_update",
    assistantMessageEvent: { type: "text_end", content: "final text" },
  });
  expect(s.messages[0].text).toBe("final text");
});

test("a user prompt then a streamed reply keep their own bubbles", () => {
  let s = withUserPrompt(emptyState(), "hi");
  s = withPiEvent(s, delta("reply"));
  expect(s.messages.map((m) => [m.role, m.text])).toEqual([
    ["user", "hi"],
    ["assistant", "reply"],
  ]);
});

test("an extension_ui_request opens a pending confirm; a confirm method only", () => {
  let s = withPiEvent(emptyState(), {
    type: "extension_ui_request",
    id: "sc-1",
    method: "confirm",
    title: "Run it?",
  });
  expect(s.confirms).toEqual([
    { id: "sc-1", title: "Run it?", state: "pending" },
  ]);

  // Non-confirm methods don't add a confirm bubble.
  s = withPiEvent(s, {
    type: "extension_ui_request",
    id: "sc-2",
    method: "input",
  });
  expect(s.confirms).toHaveLength(1);

  // Duplicate id is ignored (replays).
  s = withPiEvent(s, {
    type: "extension_ui_request",
    id: "sc-1",
    method: "confirm",
  });
  expect(s.confirms).toHaveLength(1);
});

test("answering a confirm sets allowed/denied", () => {
  let s = withPiEvent(emptyState(), {
    type: "extension_ui_request",
    id: "x",
    method: "confirm",
  });
  expect(withConfirmAnswer(s, "x", true).confirms[0].state).toBe("allowed");
  expect(withConfirmAnswer(s, "x", false).confirms[0].state).toBe("denied");
});

test("sidechannel_resolved collapses only a still-pending confirm", () => {
  let s = withPiEvent(emptyState(), {
    type: "extension_ui_request",
    id: "x",
    method: "confirm",
  });
  s = withSidechannelResolved(s, "x");
  expect(s.confirms[0].state).toBe("resolved");

  // Once answered locally, a late resolve does not overwrite the outcome.
  let answered = withConfirmAnswer(
    withPiEvent(emptyState(), {
      type: "extension_ui_request",
      id: "y",
      method: "confirm",
    }),
    "y",
    true,
  );
  answered = withSidechannelResolved(answered, "y");
  expect(answered.confirms[0].state).toBe("allowed");
});

test("unknown events are ignored", () => {
  const s = emptyState();
  expect(withPiEvent(s, { type: "tps" })).toEqual(s);
  expect(withPiEvent(s, "garbage")).toEqual(s);
  expect(withPiEvent(s, null)).toEqual(s);
});
