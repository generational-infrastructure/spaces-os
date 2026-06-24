// The credential proxy is the seam that keeps the LLM key in the supervisor
// while the loop runs in the sandbox (docs/pi-runtime-isolation-refactor.md
// §6.2). These tests pin the two things that matter: the real credential is
// injected (replacing whatever dummy the sandbox sent), and the request path +
// body + streamed response pass through verbatim to the upstream. A stub
// upstream stands in for OpenRouter; no network. ~1s.
import { afterAll, expect, test } from "bun:test";
import type { Server } from "bun";
import { startCredentialProxy } from "./proxy";

interface Captured {
  auth: string | null;
  path: string;
  body: string;
}

const captured: Captured[] = [];
const upstream = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  async fetch(req) {
    const url = new URL(req.url);
    captured.push({
      auth: req.headers.get("authorization"),
      path: url.pathname + url.search,
      body: req.method === "GET" ? "" : await req.text(),
    });
    return new Response(`echo ${url.pathname}`, { status: 200 });
  },
});
const upstreamBase = `http://127.0.0.1:${upstream.port}`;

const servers: Server[] = [upstream];
afterAll(() => {
  for (const s of servers) s.stop(true);
});

test("the real credential replaces the sandbox's dummy on every request", async () => {
  const proxy = startCredentialProxy({
    key: "real-secret",
    upstream: upstreamBase,
  });
  servers.push(proxy);
  const res = await fetch(`http://127.0.0.1:${proxy.port}/v1/models`, {
    headers: { authorization: "Bearer dummy" },
  });
  expect(res.status).toBe(200);
  const last = captured.at(-1);
  expect(last?.auth).toBe("Bearer real-secret");
  expect(last?.path).toBe("/v1/models");
});

test("the request path, query, and POST body forward verbatim", async () => {
  const proxy = startCredentialProxy({ key: "k", upstream: upstreamBase });
  servers.push(proxy);
  const res = await fetch(
    `http://127.0.0.1:${proxy.port}/chat/completions?beta=1`,
    {
      method: "POST",
      headers: {
        authorization: "Bearer dummy",
        "content-type": "application/json",
      },
      body: JSON.stringify({ model: "x", stream: true }),
    },
  );
  expect(await res.text()).toBe("echo /chat/completions");
  const last = captured.at(-1);
  expect(last?.path).toBe("/chat/completions?beta=1");
  expect(JSON.parse(last?.body ?? "{}").model).toBe("x");
});

test("a gzip-encoded upstream response is not forwarded as double-encoded", async () => {
  // Regression (test-machine openrouter mode): OpenRouter gzips /models.
  // Bun's fetch transparently inflates the body but leaves the upstream
  // `content-encoding: gzip` (and stale compressed `content-length`) on the
  // Response. Forwarding those verbatim made the child re-inflate already-
  // plaintext bytes -> Z_DATA_ERROR ("incorrect header check"), so the
  // openrouter provider never registered. The proxy must drop the stale
  // encoding headers so the decoded body matches what it advertises.
  const json = JSON.stringify({ data: [{ id: "openai/gpt-4o" }] });
  const gz = Bun.gzipSync(Buffer.from(json));
  const gzUpstream = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch() {
      return new Response(gz, {
        status: 200,
        headers: {
          "content-encoding": "gzip",
          "content-type": "application/json",
          "content-length": String(gz.length),
        },
      });
    },
  });
  servers.push(gzUpstream);
  const proxy = startCredentialProxy({
    key: "k",
    upstream: `http://127.0.0.1:${gzUpstream.port}`,
  });
  servers.push(proxy);
  // A downstream client that honors content-encoding (Bun/undici fetch) must
  // not choke reading the body.
  const res = await fetch(`http://127.0.0.1:${proxy.port}/models`);
  expect(res.headers.get("content-encoding")).toBeNull();
  expect(JSON.parse(await res.text()).data[0].id).toBe("openai/gpt-4o");
});
