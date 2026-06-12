// Headless-browser E2E for the pi-web PWA *fleet* wiring: spins up two
// pi-sessiond instances (alpha + beta), the PWA is served by alpha with both
// peers advertised via /executors, and chromium drives the UI to prove:
//
//   1. After connect, the fleet has 2 live executors (status pill is plain
//      "connected" — refreshStatus only emits the count when partial).
//   2. The "+ new chat" picker shows both peers (single-executor fleets skip
//      the picker, so its appearance is a multi-executor invariant).
//   3. Picking a peer creates a chat on that peer, and the runtime pill in
//      the chat view shows the picked peer's host.
//   4. Going back to the list, both chats coexist tagged with their hosts.
//
// LLM-free: the chats are never prompted, the daemons just need to accept
// hello + create_session. The reducer + streaming behaviour is covered by
// the single-executor pi-web-e2e check.
//
// Usage: bun multi-e2e.ts <pwa-url> <token> <alpha-host> <beta-host>
//                          <chromium-bin> <profile-dir> <cdp-port>

const [pwaUrl, token, alphaHost, betaHost, chromiumBin, profileDir, portStr] =
  process.argv.slice(2);
const port = Number(portStr);

function log(...a: unknown[]): void {
  console.error("[multi-e2e]", ...a);
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null;
}

// Wait for the (alpha) daemon to serve the PWA before launching the browser.
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
    "--no-sandbox",
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

async function evalIn(expression: string): Promise<unknown> {
  for (let attempt = 0; attempt < 2; attempt++) {
    const params: Record<string, unknown> = { expression, returnByValue: true };
    if (mainCtxId !== undefined) params.contextId = mainCtxId;
    const r = await cdp("Runtime.evaluate", params);
    if (isRecord(r.result)) {
      const exc = (r.result as { exceptionDetails?: unknown }).exceptionDetails;
      if (exc) {
        const m =
          isRecord(exc) && typeof exc.text === "string"
            ? exc.text
            : "exception";
        if (attempt === 0 && /Cannot find context|stale/.test(m)) continue;
        throw new Error(`evalIn: ${m}`);
      }
      const result = (r.result as { result?: { value?: unknown } }).result;
      return result?.value;
    }
    if (r.error) {
      const m =
        isRecord(r.error) && typeof r.error.message === "string"
          ? r.error.message
          : "evalIn error";
      if (attempt === 0 && /Cannot find context|stale|timed out/.test(m))
        continue;
      throw new Error(`evalIn: ${m}`);
    }
  }
  throw new Error("evalIn: no result");
}

async function waitFor(
  boolExpr: string,
  desc: string,
  timeoutMs = 12000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      if ((await evalIn(boolExpr)) === true) return;
    } catch {
      /* keep polling */
    }
    await Bun.sleep(100);
  }
  // Surface diagnostic context.
  let status = "";
  let title = "";
  try {
    status = String(
      await evalIn(`document.querySelector('#status')?.textContent ?? ''`),
    );
    title = String(await evalIn(`document.title ?? ''`));
  } catch {
    /* page is unresponsive */
  }
  await fail(
    `${desc} (status=${JSON.stringify(status)} title=${JSON.stringify(title)})`,
  );
}

const TOKEN = JSON.stringify(token);

// 0. PWA shell loads.
await waitFor(
  `document.readyState === 'complete' && !!document.querySelector('#token')`,
  "PWA shell never finished loading",
);

// 1. Connect with the shared token.
await evalIn(
  `document.querySelector('#token').value = ${TOKEN}; document.querySelector('#connect').click(); true`,
);
await waitFor(
  `document.querySelector('#status')?.textContent === 'connected'`,
  "never reached the fully-connected (both executors live) state",
);
log("connected (2/2 executors live)");

// 2. autoLand creates a session on the home (alpha) executor; we land in
// the chat view. The runtime pill reflects alpha's host.
await waitFor(
  `document.querySelector('#runtime-mach')?.textContent === ${JSON.stringify(alphaHost)}`,
  "runtime pill did not adopt alpha's host on auto-land",
);
log("auto-landed on alpha");

// 3. Back to list view → tap "+". Fleet has 2 executors → picker opens.
await evalIn(`document.querySelector('#back').click(); true`);
await waitFor(
  `!document.querySelector('#view-chat') || document.querySelector('#view-chat').hidden === true`,
  "back button never returned to the list",
);
await evalIn(`document.querySelector('#new-chat').click(); true`);
await waitFor(
  `document.querySelector('#picker') && document.querySelector('#picker').hidden === false`,
  "picker did not appear on multi-executor fleet",
);
const pickerRows = await evalIn(
  `Array.from(document.querySelectorAll('#picker-list .picker-row .picker-host')).map(n => n.textContent)`,
);
if (!Array.isArray(pickerRows))
  await fail(`picker rows non-array: ${JSON.stringify(pickerRows)}`);
const hosts = (pickerRows as unknown[]).map(String);
if (!hosts.includes(alphaHost) || !hosts.includes(betaHost)) {
  await fail(`picker did not list both peers: ${JSON.stringify(hosts)}`);
}
log("picker lists both peers:", hosts);

// 4. Pick beta → new chat created on beta. Runtime pill flips to beta's host.
await evalIn(
  `Array.from(document.querySelectorAll('#picker-list .picker-row')).find(r => r.querySelector('.picker-host').textContent === ${JSON.stringify(betaHost)}).click(); true`,
);
await waitFor(
  `document.querySelector('#runtime-mach')?.textContent === ${JSON.stringify(betaHost)}`,
  "runtime pill did not adopt beta's host after picker selection",
);
log("create on beta succeeded");

// 5. Back to list → both chats are visible, each tagged with the right host.
await evalIn(`document.querySelector('#back').click(); true`);
await waitFor(
  `document.querySelectorAll('#tabs .tab').length >= 2`,
  "merged chat list never showed both executors' chats",
);
const rowHosts = await evalIn(
  `Array.from(document.querySelectorAll('#tabs .tab .chat-machine')).map(n => n.textContent)`,
);
if (!Array.isArray(rowHosts))
  await fail(`row hosts non-array: ${JSON.stringify(rowHosts)}`);
const rowHostList = (rowHosts as unknown[]).map(String);
const sawAlpha = rowHostList.includes(alphaHost);
const sawBeta = rowHostList.includes(betaHost);
if (!sawAlpha || !sawBeta) {
  await fail(
    `merged list did not tag both hosts: ${JSON.stringify(rowHostList)}`,
  );
}
log("merged list tags both hosts");

console.log(
  "OK: pi-web multi-executor (discovery → fleet WS fan-out → picker → host-tagged merged list)",
);
try {
  proc.kill();
} catch {
  /* already gone */
}
process.exit(0);
