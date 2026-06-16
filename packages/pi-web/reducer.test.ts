import { expect, test } from "bun:test";

import {
  emptyState,
  withConfirmAnswer,
  withPiEvent,
  withSidechannelResolved,
  withUserImage,
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

function userMessageStart(text: string) {
  return {
    type: "message_start",
    message: {
      role: "user",
      content: [{ type: "text", text }],
      timestamp: Date.now(),
    },
  };
}

test("message_start with role=user from a sibling client renders a new user bubble", () => {
  // We had been mid-conversation: a prior turn finished. A sibling client
  // typed; the daemon emits a user message_start. We render it.
  let s = withUserPrompt(emptyState(), "hi");
  s = withPiEvent(s, { type: "agent_start" });
  s = withPiEvent(s, {
    type: "message_update",
    assistantMessageEvent: { type: "text_delta", delta: "hello!" },
  });
  s = withPiEvent(s, { type: "agent_end" });

  s = withPiEvent(s, userMessageStart("sibling-typed this"));
  expect(s.messages.map((m) => [m.role, m.text])).toEqual([
    ["user", "hi"],
    ["assistant", "hello!"],
    ["user", "sibling-typed this"],
  ]);
});

test("message_start matching the originator's optimistic bubble dedups", () => {
  // We just optimistically rendered our own prompt; the daemon echoes the
  // committed user message back via message_start. Don't double-render.
  let s = withUserPrompt(emptyState(), "hello there");
  s = withPiEvent(s, userMessageStart("hello there"));
  expect(s.messages).toEqual([
    { role: "user", text: "hello there", streaming: false },
  ]);
});

test("message_start with multi-part text content concatenates", () => {
  const s = withPiEvent(emptyState(), {
    type: "message_start",
    message: {
      role: "user",
      content: [
        { type: "text", text: "first line" },
        { type: "image", url: "data:..." },
        { type: "text", text: "second line" },
      ],
    },
  });
  expect(s.messages).toEqual([
    { role: "user", text: "first line\nsecond line", streaming: false },
  ]);
});

test("message_start with role=assistant is a no-op", () => {
  const s = withPiEvent(emptyState(), {
    type: "message_start",
    message: { role: "assistant", content: [{ type: "text", text: "x" }] },
  });
  expect(s.messages).toEqual([]);
});

test("withUserImage appends a user bubble carrying the data URL", () => {
  const url = "data:image/png;base64,AAAA";
  const s = withUserImage(emptyState(), url);
  expect(s.messages).toEqual([
    { role: "user", text: "", streaming: false, image: url },
  ]);
});

test("an image-only user echo does not double-render the optimistic bubble", () => {
  // We optimistically render our own attachment via withUserImage; the daemon
  // echoes a user message whose content is the image (no text part), which
  // extractUserText reduces to "" — so withUserMessageStart must no-op.
  const url = "data:image/png;base64,AAAA";
  let s = withUserImage(emptyState(), url);
  s = withPiEvent(s, {
    type: "message_start",
    message: {
      role: "user",
      content: [{ type: "image", source: { data: "AAAA" } }],
      timestamp: Date.now(),
    },
  });
  expect(s.messages).toEqual([
    { role: "user", text: "", streaming: false, image: url },
  ]);
});
