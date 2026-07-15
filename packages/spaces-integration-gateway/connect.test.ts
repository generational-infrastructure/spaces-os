import { expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { bridge } from "./connect";

test("bridges bytes both directions and resolves when the socket closes", async () => {
  const sock = join(mkdtempSync(join(tmpdir(), "bridge-")), "gw.sock");
  // The bridge declares its session key first; echo the client's request line
  // (skipping that notification) back, then close.
  const server = createServer((conn) => {
    let buf = "";
    conn.on("data", (d) => {
      buf += d.toString("utf8");
      let nl: number;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        const msg = JSON.parse(line);
        if (msg.method === "spaces/session") continue; // the key declaration
        conn.write(`${line}\n`);
        conn.end();
      }
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

// Capture the first line a bridge writes to the socket: the spaces/session
// notification declaring this bridge process's per-process grant key.
function firstLine(sock: string): { line: Promise<string>; close: () => void } {
  const got = Promise.withResolvers<string>();
  const server = createServer((conn) => {
    let buf = "";
    conn.on("data", (d) => {
      buf += d.toString("utf8");
      const nl = buf.indexOf("\n");
      if (nl >= 0) got.resolve(buf.slice(0, nl));
    });
  });
  const listening = Promise.withResolvers<void>();
  server.listen(sock, () => listening.resolve());
  return {
    line: listening.promise.then(() => got.promise),
    close: () => server.close(),
  };
}

test("bridge declares a spaces/session key as its first socket line", async () => {
  const sock = join(mkdtempSync(join(tmpdir(), "bridge-")), "gw.sock");
  const cap = firstLine(sock);

  const input = new PassThrough();
  bridge(sock, input, new PassThrough());
  input.write('{"jsonrpc":"2.0","id":1}\n'); // client bytes follow the notification

  const first = JSON.parse(await cap.line);
  expect(first.jsonrpc).toBe("2.0");
  expect(first.method).toBe("spaces/session");
  expect(typeof first.params.key).toBe("string");
  expect(first.params.key.length).toBeGreaterThan(0);
  expect("id" in first).toBe(false); // a notification, no id
  cap.close();
});

test("distinct bridge invocations declare distinct keys", async () => {
  const dir = mkdtempSync(join(tmpdir(), "bridge-"));
  const sockA = join(dir, "a.sock");
  const sockB = join(dir, "b.sock");
  const capA = firstLine(sockA);
  const capB = firstLine(sockB);

  bridge(sockA, new PassThrough(), new PassThrough());
  bridge(sockB, new PassThrough(), new PassThrough());

  const keyA = JSON.parse(await capA.line).params.key;
  const keyB = JSON.parse(await capB.line).params.key;
  expect(keyA).not.toBe(keyB);
  capA.close();
  capB.close();
});
