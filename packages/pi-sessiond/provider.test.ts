import { afterAll, expect, test } from "bun:test";

import { fetchModels } from "./provider";

// A throwaway OpenAI-ish /v1/models endpoint that records the Authorization
// header it was called with and 401s when a key is required but absent/wrong.
function startServer(requiredKey: string | null) {
  let seenAuth: string | null = null;
  const server = Bun.serve({
    port: 0,
    fetch(req) {
      const url = new URL(req.url);
      if (url.pathname !== "/v1/models")
        return new Response("nope", { status: 404 });
      seenAuth = req.headers.get("authorization");
      if (requiredKey && seenAuth !== `Bearer ${requiredKey}`) {
        return new Response("unauthorized", { status: 401 });
      }
      return Response.json({
        object: "list",
        data: [{ id: "gemma4:e4b", context_length: 8192, max_tokens: 512 }],
      });
    },
  });
  return {
    base: `http://127.0.0.1:${server.port}`,
    auth: () => seenAuth,
    stop: () => server.stop(true),
  };
}

const servers: { stop: () => void }[] = [];
afterAll(() => {
  for (const s of servers) s.stop();
});

test("discovery sends the api key as a Bearer token", async () => {
  const srv = startServer("sk-secret");
  servers.push(srv);

  const models = await fetchModels(srv.base, "sk-secret");

  expect(srv.auth()).toBe("Bearer sk-secret");
  expect(models).toEqual([
    { id: "gemma4:e4b", contextLength: 8192, maxTokens: 512 },
  ]);
});

test("a key-protected endpoint rejects a missing key and yields no models", async () => {
  const srv = startServer("sk-secret");
  servers.push(srv);

  const models = await fetchModels(srv.base, "");

  expect(srv.auth()).toBeNull();
  expect(models).toEqual([]);
});

test("a default-allow endpoint still discovers models (header ignored)", async () => {
  const srv = startServer(null);
  servers.push(srv);

  const models = await fetchModels(srv.base, "dummy");

  expect(srv.auth()).toBe("Bearer dummy");
  expect(models.map((m) => m.id)).toEqual(["gemma4:e4b"]);
});

test("trailing slashes on the base url are normalized", async () => {
  const srv = startServer(null);
  servers.push(srv);

  const models = await fetchModels(`${srv.base}//`, "dummy");

  expect(models).toHaveLength(1);
});
