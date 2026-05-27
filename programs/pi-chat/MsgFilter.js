.pragma library

// Filter helper for the chat history view. Returns the slice the UI
// should render given the current visibility toggle. The underlying
// session.messages array is never mutated — toggling reveals previously
// hidden bubbles in place rather than replaying them.
function visible(messages, showThinking) {
  if (showThinking) return messages;
  return messages.filter(m => (m.type || "") !== "thinking");
}
