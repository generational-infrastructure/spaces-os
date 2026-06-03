// Pure conversation-state reducer for the pi-web PWA.
//
// pi's stdout events arrive (inside §12 `event` envelopes) as the same shapes
// the quickshell panel's PiSession._handleEvent consumes. This module folds
// them into a plain ChatState so the DOM layer (app.ts) just renders state —
// and so the bug-prone event handling is unit-testable without a browser.

export type Role = "user" | "assistant";

export interface ChatMessage {
  role: Role;
  text: string;
  streaming: boolean; // assistant text still arriving (deltas)
}

export type ConfirmState = "pending" | "allowed" | "denied" | "resolved";

export interface ChatConfirm {
  id: string;
  title: string;
  state: ConfirmState;
}

export interface ChatState {
  messages: ChatMessage[];
  confirms: ChatConfirm[];
  typing: boolean; // agent mid-turn
}

export function emptyState(): ChatState {
  return { messages: [], confirms: [], typing: false };
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null;
}
function str(v: unknown): string {
  return typeof v === "string" ? v : "";
}

// Append/extend the trailing streaming assistant message, starting one if none.
function intoStreaming(state: ChatState, mutate: (text: string) => string): ChatState {
  const messages = state.messages.slice();
  const last = messages[messages.length - 1];
  if (last && last.role === "assistant" && last.streaming) {
    messages[messages.length - 1] = { ...last, text: mutate(last.text) };
  } else {
    messages.push({ role: "assistant", text: mutate(""), streaming: true });
  }
  return { ...state, messages };
}

function finalizeStreaming(state: ChatState): ChatState {
  const messages = state.messages.slice();
  const last = messages[messages.length - 1];
  if (last && last.role === "assistant" && last.streaming) {
    messages[messages.length - 1] = { ...last, streaming: false };
  }
  return { ...state, messages };
}

function withMessageUpdate(state: ChatState, me: unknown): ChatState {
  if (!isRecord(me)) return state;
  switch (me.type) {
    case "text_start":
      return intoStreaming(state, (t) => t); // ensure a streaming bubble exists
    case "text_delta":
      return intoStreaming(state, (t) => t + str(me.delta));
    case "text_end":
      return typeof me.content === "string"
        ? intoStreaming(state, () => str(me.content))
        : state;
    default:
      return state;
  }
}

function withConfirmRequest(state: ChatState, ev: Record<string, unknown>): ChatState {
  const id = str(ev.id);
  if (!id || state.confirms.some((c) => c.id === id)) return state;
  return {
    ...state,
    confirms: [
      ...state.confirms,
      { id, title: str(ev.title) || "Run shell command?", state: "pending" },
    ],
  };
}

// Fold one pi event (the envelope's `payload`) into the conversation.
export function withPiEvent(state: ChatState, ev: unknown): ChatState {
  if (!isRecord(ev)) return state;
  switch (ev.type) {
    case "agent_start":
      return { ...state, typing: true };
    case "agent_end":
      return finalizeStreaming({ ...state, typing: false });
    case "message_update":
      return withMessageUpdate(state, ev.assistantMessageEvent);
    case "extension_ui_request":
      return str(ev.method) === "confirm" ? withConfirmRequest(state, ev) : state;
    default:
      return state;
  }
}

// A prompt the user just sent (echoed locally before pi streams its reply).
export function withUserPrompt(state: ChatState, text: string): ChatState {
  return { ...state, messages: [...state.messages, { role: "user", text, streaming: false }] };
}

// Local resolution of a confirm (this client answered).
export function withConfirmAnswer(state: ChatState, id: string, allowed: boolean): ChatState {
  return setConfirm(state, id, allowed ? "allowed" : "denied");
}

// Another mirrored client answered first (daemon `sidechannel_resolved`).
export function withSidechannelResolved(state: ChatState, id: string): ChatState {
  return setConfirm(state, id, "resolved", true);
}

function setConfirm(
  state: ChatState,
  id: string,
  next: ConfirmState,
  onlyPending = false,
): ChatState {
  return {
    ...state,
    confirms: state.confirms.map((c) =>
      c.id === id && (!onlyPending || c.state === "pending") ? { ...c, state: next } : c,
    ),
  };
}
