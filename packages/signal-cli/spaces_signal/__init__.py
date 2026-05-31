"""Signal skill backend for the spaces AI agent.

Two binaries ship from this package:

* `signal` — the agent-facing CLI invoked from inside the pi-chat
  sandbox. Reads messages from a local SQLite store and enqueues
  outbound sends through `spaces_signal.bridge` via a unix socket.

* `spaces-signal-bridge` — the always-up host-side service that
  subscribes to signal-cli's JSON-RPC daemon, persists incoming
  messages to the same SQLite store, and brokers outbound sends:
  self-sends go through immediately, everything else lands in a
  `pending_sends` table awaiting human approval from the chat panel.
"""
