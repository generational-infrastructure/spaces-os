// Pi extension: register OpenRouter as provider "openrouter" pointing at the
// supervisor's credential-injection proxy, NOT at openrouter.ai directly.
//
// The runtime-isolation refactor (docs/pi-runtime-isolation-refactor.md §6.2)
// runs the model loop in the session sandbox, but the OpenRouter key must stay
// in the supervisor. So the supervisor runs a loopback proxy that injects the
// real key, and exports its URL as OPENROUTER_PROXY_URL. This extension, loaded
// inside the sandboxed child, configures the provider to talk to that proxy
// with a DUMMY key — the real credential never enters the sandbox. The catalog
// is fetched through the proxy (which injects the key for /models too).
//
// No-op when OPENROUTER_PROXY_URL is unset (no key configured): OpenRouter is
// simply unavailable in that session, the local provider still works.

export default async function (pi) {
  const baseUrl = process.env.OPENROUTER_PROXY_URL;
  if (!baseUrl) return;

  try {
    const res = await fetch(`${baseUrl}/models`);
    if (!res.ok) {
      console.error(`openrouter-proxy: GET /models -> HTTP ${res.status}`);
      return;
    }
    const payload = await res.json();
    const data = Array.isArray(payload?.data) ? payload.data : [];
    pi.registerProvider("openrouter", {
      baseUrl,
      apiKey: "dummy", // the real key is injected by the supervisor's proxy
      api: "openai-completions",
      models: data.map((m) => ({
        id: m.id,
        name: m.name ?? m.id,
        reasoning: false,
        input: ["text", "image"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: m.context_length ?? 128000,
        maxTokens: m.max_tokens ?? 4096,
      })),
    });
  } catch (err) {
    console.error("openrouter-proxy: failed to register provider", err);
  }
}
