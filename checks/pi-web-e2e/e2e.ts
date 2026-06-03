// Headless-browser E2E for the pi-web PWA. Launches chromium (headless, CDP)
// against the PWA served by a real pi-sessiond (fake pi behind a systemd-run
// stub) and drives the DOM over raw CDP — no npm:
//   token -> connect -> a session becomes active -> prompt -> the streamed
//   reply renders; then a "confirm" prompt -> the confirm card -> Allow -> it
//   resolves. Each in-page evaluate is a synchronous DOM read/click; polling is
//   driven from here (so the page never needs its own promises).
//
// Usage: bun e2e.ts <pwa-url> <token> <chromium-bin> <profile-dir> <cdp-port>
const [pwaUrl, token, chromiumBin, profileDir, portStr] = process.argv.slice(2);
const port = Number(portStr);

function log(...a: unknown[]): void {
  console.error("[e2e]", ...a);
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null;
}

// Wait for the daemon to serve the PWA before launching the browser.
{
  const deadline = Date.now() + 15000;
  for (;;) {
    try {
      if ((await fetch(pwaUrl)).ok) break;
    } catch {
      /* daemon not up yet */
    }
    if (Date.now() > deadline) {
      log("FAIL: daemon never served the PWA at", pwaUrl);
      process.exit(1);
    }
    await Bun.sleep(200);
  }
}

const proc = Bun.spawn(
  [
    chromiumBin,
    "--headless=new",
    "--no-sandbox", // build sandbox can't nest user namespaces
    "--disable-gpu",
    "--disable-dev-shm-usage",
    "--disable-software-rasterizer",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-extensions",
    "--disable-background-networking",
    "--disable-sync",
    "--metrics-recording-only",
    `--user-data-dir=${profileDir}`,
    `--remote-debugging-port=${port}`,
    pwaUrl,
  ],
  { stdout: "pipe", stderr: "pipe" },
);

async function fail(msg: string): Promise<never> {
  log("FAIL:", msg);
  try {
    proc.kill();
  } catch {
    /* already gone */
  }
  try {
    const err = await new Response(proc.stderr).text();
    if (err.trim()) log("chromium stderr (tail):\n" + err.slice(-6000));
  } catch {
    /* nothing to show */
  }
  process.exit(1);
}

// The page target's CDP WebSocket (chromium opened the PWA url as the page).
async function pageWs(): Promise<string> {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    try {
      const targets = (await (
        await fetch(`http://127.0.0.1:${port}/json`)
      ).json()) as Array<{
        type: string;
        url?: string;
        webSocketDebuggerUrl?: string;
      }>;
      const page = targets.find(
        (t) => t.type === "page" && t.webSocketDebuggerUrl,
      );
      if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
    } catch {
      /* CDP endpoint not up yet */
    }
    await Bun.sleep(250);
  }
  return fail("chromium CDP page target never appeared");
}

interface CdpResponse {
  id?: number;
  result?: unknown;
  error?: unknown;
}

const sock = new WebSocket(await pageWs());
{
  const { promise, resolve, reject } = Promise.withResolvers<void>();
  sock.onopen = () => resolve();
  sock.onerror = () => reject(new Error("CDP socket error"));
  await promise.catch(() => fail("could not open the CDP socket"));
}

let nextId = 1;
const pending = new Map<number, (r: CdpResponse) => void>();
// The main frame's execution context. The target commits the PWA navigation
// before its JS context replaces the initial empty document's, so evaluating in
// the *default* context can hit a stale about:blank; track the newest context
// and evaluate explicitly in it (executionContextsCleared resets it).
let mainCtxId: number | undefined;
sock.onmessage = (e) => {
  const msg: unknown = JSON.parse(String(e.data));
  if (!isRecord(msg)) return;
  if (typeof msg.id === "number") {
    pending.get(msg.id)?.(msg as CdpResponse);
    pending.delete(msg.id);
    return;
  }
  if (
    msg.method === "Runtime.executionContextCreated" &&
    isRecord(msg.params)
  ) {
    const ctx = msg.params.context;
    const aux = isRecord(ctx) && isRecord(ctx.auxData) ? ctx.auxData : {};
    if (isRecord(ctx) && typeof ctx.id === "number") {
      if (aux.isDefault === true) mainCtxId = ctx.id;
    }
  } else if (
    msg.method === "Runtime.executionContextDestroyed" &&
    isRecord(msg.params)
  ) {
    if (msg.params.executionContextId === mainCtxId) mainCtxId = undefined;
  } else if (msg.method === "Runtime.executionContextsCleared") {
    mainCtxId = undefined;
  }
};

function cdp(
  method: string,
  params: Record<string, unknown> = {},
): Promise<CdpResponse> {
  const id = nextId++;
  const { promise, resolve } = Promise.withResolvers<CdpResponse>();
  pending.set(id, resolve);
  // A non-responding browser (e.g. context torn down mid-navigation) must not
  // hang the await; resolve as a transient error so waitFor retries/times out.
  const timer = setTimeout(() => {
    if (pending.delete(id))
      resolve({ id, error: { message: "cdp call timed out" } });
  }, 5000);
  sock.send(JSON.stringify({ id, method, params }));
  return promise.then((r) => {
    clearTimeout(timer);
    return r;
  });
}

await cdp("Runtime.enable");

// Evaluate a synchronous expression in the page; throw on a JS exception.
async function evalIn(expression: string): Promise<unknown> {
  for (let attempt = 0; attempt < 2; attempt++) {
    const params: Record<string, unknown> = { expression, returnByValue: true };
    if (mainCtxId !== undefined) params.contextId = mainCtxId;
    const r = await cdp("Runtime.evaluate", params);
    if (isRecord(r.error)) {
      // Stale/invalid context id (e.g. it was destroyed): drop it and retry once
      // against the page's current default context.
      if (mainCtxId !== undefined) {
        mainCtxId = undefined;
        continue;
      }
      return undefined; // transient, no pinned context
    }
    const result = isRecord(r.result) ? r.result : {};
    if (isRecord(result.exceptionDetails)) {
      const ex = result.exceptionDetails;
      const exObj = isRecord(ex.exception) ? ex.exception : {};
      throw new Error(
        String(exObj.description ?? ex.text ?? JSON.stringify(ex)),
      );
    }
    const inner = isRecord(result.result) ? result.result : {};
    return inner.value;
  }
  return undefined;
}

// Poll a boolean expression from here; on timeout, surface status + log text.
async function waitFor(
  boolExpr: string,
  desc: string,
  timeoutMs = 12000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    let ok = false;
    try {
      ok = (await evalIn(boolExpr)) === true;
    } catch {
      ok = false; // transient eval failure during navigation/load
    }
    if (ok) return;
    if (Date.now() > deadline) {
      const st = await evalIn(
        `(document.querySelector('#status')||{}).textContent || ''`,
      );
      const body = await evalIn(
        `(document.querySelector('#log')||{}).textContent || ''`,
      );
      await fail(
        `${desc} (status=${JSON.stringify(st)}, log=${JSON.stringify(body)})`,
      );
    }
    await Bun.sleep(150);
  }
}

const TOKEN = JSON.stringify(token);

// We connected straight to the PWA page target; wait for it to finish loading
// (app.js runs main() and wires the gate) before driving the DOM.
await waitFor(
  `document.readyState === 'complete' && !!document.querySelector('#token') && !!document.querySelector('#connect')`,
  "PWA shell never finished loading (app.js wiring the gate)",
);

// 1. Enter the token and connect.
await evalIn(
  `document.querySelector('#token').value = ${TOKEN}; document.querySelector('#connect').click(); true`,
);
await waitFor(
  `!!document.querySelector('#status') && document.querySelector('#status').textContent === 'connected'`,
  "never reached the connected state",
);
log("connected");

// 2. A session becomes active on first connect; send a prompt, await the reply.
await waitFor(
  `!!document.querySelector('#tabs .tab.active')`,
  "no active session after connect",
);
await evalIn(
  `document.querySelector('#input').value = 'hello'; document.querySelector('#send').click(); true`,
);
await waitFor(
  `(document.querySelector('#log').textContent || '').includes('Hello from pi-web!')`,
  "streamed reply never rendered",
);
log("streamed reply rendered");

// 3. Confirm side-channel: a pending card -> Allow -> resolved.
await evalIn(
  `document.querySelector('#input').value = 'please confirm'; document.querySelector('#send').click(); true`,
);
await waitFor(
  `!!document.querySelector('.confirm.pending .allow')`,
  "confirm card never appeared",
);
await evalIn(`document.querySelector('.confirm.pending .allow').click(); true`);
await waitFor(
  `!document.querySelector('.confirm.pending') && !!document.querySelector('.confirm.allowed')`,
  "confirm not resolved after Allow",
);
log("confirm allowed + resolved");

console.log(
  "OK: pi-web E2E in headless chromium (connect, prompt+streamed reply, confirm+Allow)",
);
try {
  proc.kill();
} catch {
  /* already gone */
}
process.exit(0);
