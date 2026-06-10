// Pi extension: discover models from llama-swap's OpenAI-compatible
// /v1/models endpoint and register them as provider "local".
//
// Configured by the pi-chat NixOS module. The endpoint base URL
// (without /v1 suffix) is passed in via the LLAMA_SWAP_BASE_URL env var.
//
// Pi awaits this async factory before startup completes, so the
// discovered list is available to !models, !model, and --list-models.

export default async function (pi) {
  const root = process.env.LLAMA_SWAP_BASE_URL;
  if (!root) {
    console.error("llama-swap-discover: LLAMA_SWAP_BASE_URL not set");
    return;
  }
  const baseUrl = `${root.replace(/\/+$/, "")}/v1`;

  try {
    const res = await fetch(`${baseUrl}/models`);
    if (!res.ok) {
      console.error(
        `llama-swap-discover: GET /v1/models -> HTTP ${res.status}`,
      );
      return;
    }
    const payload = await res.json();
    const data = Array.isArray(payload?.data) ? payload.data : [];
    if (data.length === 0) {
      console.warn("llama-swap-discover: /v1/models returned no entries");
    }
    pi.registerProvider("local", {
      baseUrl,
      apiKey: "dummy",
      api: "openai-completions",
      compat: {
        supportsDeveloperRole: false,
        supportsReasoningEffort: false,
      },
      models: data.map((m) => ({
        id: m.id,
        name: m.id,
        reasoning: false,
        input: ["text", "image"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: m.context_length ?? m.max_model_len ?? 128000,
        maxTokens: m.max_tokens ?? 4096,
      })),
    });
  } catch (err) {
    console.error("llama-swap-discover: failed to discover models", err);
  }
}
