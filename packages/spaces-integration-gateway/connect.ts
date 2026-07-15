/**
 * spaces-mcp-connect: a stdio↔unix-socket bridge so an MCP-native harness that
 * only speaks stdio (Claude Code, Cursor, …) can reach the gateway. Point its
 * server `command` at this binary; it pipes stdin→socket and socket→stdout,
 * resolving when either side closes. The gateway itself is a persistent --user
 * service, so many harnesses share one instance (and one confirm/grant state).
 */

import { randomUUID } from "node:crypto";
import { createConnection } from "node:net";

export function bridge(
  socketPath: string,
  input: NodeJS.ReadableStream,
  output: NodeJS.WritableStream,
): Promise<void> {
  // One random key per bridge invocation. The CLI calls bridge exactly once per
  // process, so this key's lifetime is the bridge process's: the gateway's
  // per-process grant set dies with the bridge.
  const sessionKey = randomUUID();
  const { promise, resolve } = Promise.withResolvers<void>();
  const sock = createConnection(socketPath);
  let settled = false;
  const finish = () => {
    if (settled) return;
    settled = true;
    resolve();
  };
  sock.on("connect", () => {
    // Declare this process's session key BEFORE any client bytes, so grants are
    // shared across the bridge's (single) connection with per-process lifetime.
    sock.write(
      `${JSON.stringify({ jsonrpc: "2.0", method: "spaces/session", params: { key: sessionKey } })}\n`,
    );
    input.pipe(sock);
    sock.pipe(output);
  });
  sock.on("close", finish);
  sock.on("error", finish);
  return promise;
}

// CLI entry (spaces-mcp-connect): bridge stdio ↔ the gateway socket. Skipped
// under the test runner (import.meta.main is false there).
if (import.meta.main) {
  const socketPath =
    process.argv[2] ?? process.env.SPACES_INTEGRATION_GATEWAY_SOCKET ?? "";
  if (!socketPath) {
    console.error(
      "spaces-mcp-connect: no gateway socket (pass a path or set SPACES_INTEGRATION_GATEWAY_SOCKET)",
    );
    process.exit(2);
  }
  await bridge(socketPath, process.stdin, process.stdout);
  process.exit(0);
}
