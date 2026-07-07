"""Signal daemon → messages.db forwarder for the spaces AI agent.

One binary ships from this package:

* `spaces-signal-bridge` — the always-up host-side service that
  subscribes to signal-cli's JSON-RPC daemon and persists incoming
  messages into a local SQLite store. That store is read (mode=ro) by
  the integration-signal MCP server, which owns the agent-facing tool
  surface (threads/read/search/contacts/groups/send/…) behind the
  gateway.
"""
