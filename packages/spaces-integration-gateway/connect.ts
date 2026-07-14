/**
 * spaces-mcp-connect: a stdio↔unix-socket bridge so an MCP-native harness that
 * only speaks stdio (Claude Code, Cursor, …) can reach the gateway. Point its
 * server `command` at this binary; it pipes stdin→socket and socket→stdout,
 * resolving when either side closes. The gateway itself is a persistent --user
 * service, so many harnesses share one instance (and one confirm/grant state).
 */

import { createConnection } from "node:net";

export function bridge(
  socketPath: string,
  input: NodeJS.ReadableStream,
  output: NodeJS.WritableStream,
): Promise<void> {
  const { promise, resolve } = Promise.withResolvers<void>();
  const sock = createConnection(socketPath);
  let settled = false;
  const finish = () => {
    if (settled) return;
    settled = true;
    resolve();
  };
  sock.on("connect", () => {
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
