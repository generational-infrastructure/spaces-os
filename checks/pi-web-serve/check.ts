// Asserts the daemon serves the bundled PWA over HTTP: the app shell, the
// bundled app.js (with the reducer), the PWA manifest/sw/icon, and the SPA
// fallback (unknown path -> index.html). Run: bun check.ts <base-url>.
const base = process.argv[2];

async function get(path: string): Promise<string> {
  const deadline = Date.now() + 15000;
  for (;;) {
    try {
      const res = await fetch(base + path);
      if (!res.ok) throw new Error(`GET ${path} -> ${res.status}`);
      return await res.text();
    } catch (e) {
      if (Date.now() > deadline) throw e; // daemon never came up
      await Bun.sleep(200);
    }
  }
}

// The static <title> is the "loading" placeholder app.ts replaces once it
// knows the executor host (see app.ts: main() / viewList() / renderChatHead()).
// We just assert the shell was served — the literal text isn't load-bearing.
const index = await get("/");
if (!index.includes("<title>pi · loading…</title>"))
  throw new Error("index.html missing the app shell");

const appjs = await get("/app.js");
if (!appjs.includes("withPiEvent"))
  throw new Error("app.js missing the bundled reducer");
for (const asset of ["/manifest.webmanifest", "/sw.js", "/icon.svg"])
  await get(asset);

// Discovery endpoint: PWA fan-out target list. Asserts the daemon's `self`
// matches its EXECUTOR_ID and that the peer list round-trips verbatim from
// the SPACES_SESSIOND_PEERS env. Validates the (id, host) shape too.
const disc = JSON.parse(await get("/executors")) as {
  self: string;
  executors: { id: string; host: string }[];
};
if (disc.self !== "alpha")
  throw new Error(`/executors self mismatch: ${disc.self}`);
if (disc.executors.length !== 2)
  throw new Error(
    `/executors expected 2 entries, got ${disc.executors.length}`,
  );
const beta = disc.executors.find((e) => e.id === "beta");
if (!beta || beta.host !== "127.0.0.1:8791")
  throw new Error(
    `/executors missing beta peer: ${JSON.stringify(disc.executors)}`,
  );

// Client-side routing: an unknown path serves index.html, not a 404.
const fallback = await get("/no/such/route");
if (!fallback.includes("<title>pi · loading…</title>"))
  throw new Error("SPA fallback did not serve index.html");

console.log("OK: PWA served (index, app.js, manifest, sw, icon, SPA fallback)");
