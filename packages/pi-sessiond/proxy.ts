// A loopback credential-injection proxy (docs/pi-runtime-isolation-refactor.md
// §6.2). The LLM loop runs in the session sandbox, but the provider key must
// stay in the supervisor (req: secrets never enter a model-steerable domain).
// So the supervisor runs this tiny reverse-proxy: the child's "openrouter"
// provider points at it with a DUMMY key, and every request is forwarded
// upstream with the real `Authorization: Bearer <key>` injected here. The
// sandbox holds only the proxy URL + a dummy key; the secret never crosses the
// rpc boundary or the sandbox.
//
// Kept transport-only: it forwards verbatim (status, headers, streamed body)
// and injects exactly one header, so streamed chat completions pass through.
import type { Server } from "bun";

export interface CredentialProxyOptions {
  key: string; // the real upstream credential — stays in this process
  upstream: string; // upstream base, e.g. "https://openrouter.ai/api/v1"
  host?: string; // bind address (default loopback)
  port?: number; // 0 → an ephemeral port (read back from server.port)
}

// Start the proxy and return the running Bun server (read `.port` for the URL).
export function startCredentialProxy(opts: CredentialProxyOptions): Server {
  const upstream = opts.upstream.replace(/\/+$/, "");
  return Bun.serve({
    hostname: opts.host ?? "127.0.0.1",
    port: opts.port ?? 0,
    async fetch(req) {
      const url = new URL(req.url);
      const target = `${upstream}${url.pathname}${url.search}`;
      const headers = new Headers(req.headers);
      // Replace whatever dummy credential the sandbox sent with the real one.
      headers.set("authorization", `Bearer ${opts.key}`);
      headers.delete("host"); // let fetch set it for the upstream
      const hasBody = req.method !== "GET" && req.method !== "HEAD";
      const res = await fetch(target, {
        method: req.method,
        headers,
        body: hasBody ? await req.arrayBuffer() : undefined,
      });
      // Bun's fetch transparently inflates a compressed upstream body but
      // leaves the upstream `content-encoding` (and now-wrong compressed
      // `content-length`) on the Response. Forwarding them verbatim makes the
      // downstream client re-inflate already-plaintext bytes (Z_DATA_ERROR /
      // "incorrect header check"). Drop both so the decoded body matches its
      // advertised headers; the body stream still passes through untouched.
      const respHeaders = new Headers(res.headers);
      respHeaders.delete("content-encoding");
      respHeaders.delete("content-length");
      return new Response(res.body, {
        status: res.status,
        statusText: res.statusText,
        headers: respHeaders,
      });
    },
  });
}
