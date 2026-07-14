import { expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { bridge } from "./connect";

test("bridges bytes both directions and resolves when the socket closes", async () => {
  const sock = join(mkdtempSync(join(tmpdir(), "bridge-")), "gw.sock");
  // Echo one chunk back, then close the connection.
  const server = createServer((conn) => {
    conn.on("data", (d) => {
      conn.write(d);
      conn.end();
    });
  });
  const listening = Promise.withResolvers<void>();
  server.listen(sock, () => listening.resolve());
  await listening.promise;

  const input = new PassThrough();
  const output = new PassThrough();
  const got: Buffer[] = [];
  output.on("data", (c) => got.push(Buffer.from(c)));

  const done = bridge(sock, input, output);
  input.write('{"jsonrpc":"2.0","id":1}\n');
  await done; // resolves once the server ends the connection
  expect(Buffer.concat(got).toString()).toBe('{"jsonrpc":"2.0","id":1}\n');
  server.close();
});

test("resolves (never hangs) when the socket is unreachable", async () => {
  const sock = join(mkdtempSync(join(tmpdir(), "bridge-")), "nope.sock");
  await bridge(sock, new PassThrough(), new PassThrough());
});
