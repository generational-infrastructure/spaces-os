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

const index = await get("/");
if (!index.includes("<title>pi</title>"))
  throw new Error("index.html missing the app shell");

const appjs = await get("/app.js");
if (!appjs.includes("withPiEvent"))
  throw new Error("app.js missing the bundled reducer");

for (const asset of ["/manifest.webmanifest", "/sw.js", "/icon.svg"])
  await get(asset);

// Client-side routing: an unknown path serves index.html, not a 404.
const fallback = await get("/no/such/route");
if (!fallback.includes("<title>pi</title>"))
  throw new Error("SPA fallback did not serve index.html");

console.log("OK: PWA served (index, app.js, manifest, sw, icon, SPA fallback)");
