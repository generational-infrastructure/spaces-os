// Model discovery against this executor's OpenAI-compatible LLM endpoint
// (its co-located llama-swap). Split out of main.ts so the auth-header
// contract is unit-testable without booting the whole daemon.
//
// When llama-swap is configured with `apiKeys` (the clan `pi` service does
// this by default), every request — including the boot-time `/v1/models`
// discovery and every chat completion — must carry the key or llama-swap
// answers 401. The daemon loads that key (loadLlamaSwapKey in main.ts) and
// threads it through here.

export interface DiscoveredModel {
  id: string;
  contextLength: number;
  maxTokens: number;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
function asNumber(value: unknown): number | undefined {
  return typeof value === "number" ? value : undefined;
}

// GET <baseUrl>/v1/models, authenticated with the llama-swap API key.
// `baseUrl` is the LLM base WITHOUT the `/v1` suffix (matches LLAMA_SWAP_BASE_URL).
// A non-empty key is sent as a Bearer token; against a default-allow llama-swap
// (no `apiKeys`) the header is simply ignored, so it is always safe to attach.
// Returns [] on any non-200 (e.g. a 401 from a key-protected llama-swap when
// the key is missing/wrong) so the caller falls back to the default model.
export async function fetchModels(
  baseUrl: string,
  apiKey: string,
): Promise<DiscoveredModel[]> {
  const url = `${baseUrl.replace(/\/+$/, "")}/v1/models`;
  const headers = apiKey ? { Authorization: `Bearer ${apiKey}` } : {};
  const res = await fetch(url, { headers });
  if (!res.ok) return [];
  const payload: unknown = await res.json();
  const data =
    isRecord(payload) && Array.isArray(payload.data) ? payload.data : [];
  return data
    .filter(isRecord)
    .map((m) => ({
      id: typeof m.id === "string" ? m.id : "",
      contextLength:
        asNumber(m.context_length) ?? asNumber(m.max_model_len) ?? 128000,
      maxTokens: asNumber(m.max_tokens) ?? 4096,
    }))
    .filter((m) => m.id.length > 0);
}
