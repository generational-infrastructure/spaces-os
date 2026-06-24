// Thin supervisor-side driver for a headless pi child (`pi --mode rpc`).
//
// The runtime-isolation refactor (docs/pi-runtime-isolation-refactor.md)
// inverts the daemon: instead of embedding pi in-process at uid 1000, the
// supervisor spawns one pi rpc-mode child per session and drives it over a
// single JSON-line pipe. This module owns that pipe and nothing else — it is
// the entire trusted control surface over the (later sandboxed) runtime.
//
// It splits the child's stdout into three streams:
//   - correlated command responses, awaited by `request()`;
//   - extension_ui_request side-channel frames (confirm/select/input/…),
//     surfaced via `onExtensionUI`;
//   - the AgentSessionEvent stream, surfaced verbatim via `onEvent`.
//
// We deliberately do NOT reuse the SDK's RpcClient: it hardcodes
// `spawn("node", cliPath)` (we must launch the child inside a managed-userns
// unit), it has no extension_ui response path (the load-bearing approval
// channel), and its single-consumer request/response model fights the
// supervisor's multi-client fan-out. We keep only pi's wire protocol.
import { type ChildProcess, spawn } from "node:child_process";

// A parsed JSON-line frame from the child: an event, a response, or a
// ui-request. Kept structural (the typed unions live in pi's rpc-types, only
// partially exported from the SDK; the supervisor re-stamps shapes anyway).
export type RpcFrame = Record<string, unknown>;

export interface RpcDriverOptions {
  // The child command; argv[0] is the binary. The daemon passes
  // `pi --mode rpc …` directly today and the sandbox-wrapped argv later — the
  // driver is agnostic to which, so phase 2 needs no driver change.
  argv: string[];
  cwd?: string;
  // Extra env merged over the parent's. Undefined → inherit the parent's env.
  env?: Record<string, string>;
  // The session event stream: every frame that is neither a correlated
  // response nor a ui-request. Forwarded verbatim to attached clients.
  onEvent: (frame: RpcFrame) => void;
  // extension_ui_request frames: surfaced to the panel as a side-channel.
  onExtensionUI: (frame: RpcFrame) => void;
  // The child exited (crash, or our own stop()).
  onExit?: (code: number | null, signal: NodeJS.Signals | null) => void;
}

// Split a byte stream into newline-delimited frames. Mirrors pi's own jsonl
// reader (not exported through the SDK's `exports` map), kept tiny on purpose.
function attachLineReader(
  stream: NodeJS.ReadableStream,
  onLine: (line: string) => void,
): void {
  let buf = "";
  stream.on("data", (chunk: Buffer) => {
    buf += chunk.toString("utf8");
    let nl = buf.indexOf("\n");
    while (nl !== -1) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      if (line.length > 0) onLine(line);
      nl = buf.indexOf("\n");
    }
  });
}

export class RpcDriver {
  private readonly child: ChildProcess;
  private nextId = 0;
  private readonly pending = new Map<string, (frame: RpcFrame) => void>();
  private stopped = false;

  constructor(private readonly opts: RpcDriverOptions) {
    const [cmd, ...args] = opts.argv;
    this.child = spawn(cmd, args, {
      cwd: opts.cwd,
      env: opts.env ? { ...process.env, ...opts.env } : process.env,
      // stderr inherits so the child's logs land in the daemon's journal.
      stdio: ["pipe", "pipe", "inherit"],
    });
    attachLineReader(this.child.stdout as NodeJS.ReadableStream, (line) =>
      this.handleLine(line),
    );
    this.child.on("exit", (code, signal) => {
      this.stopped = true;
      for (const resolve of this.pending.values())
        resolve({
          type: "response",
          success: false,
          error: "rpc child exited",
        });
      this.pending.clear();
      this.opts.onExit?.(code, signal);
    });
  }

  // The child's pid, for sandbox/wall checks and diagnostics.
  get pid(): number | undefined {
    return this.child.pid;
  }

  private handleLine(line: string): void {
    let frame: RpcFrame;
    try {
      frame = JSON.parse(line) as RpcFrame;
    } catch {
      return; // non-JSON noise on stdout is ignored, never crashes the pipe
    }
    if (frame.type === "response") {
      const id = typeof frame.id === "string" ? frame.id : undefined;
      const resolve = id ? this.pending.get(id) : undefined;
      if (id && resolve) {
        this.pending.delete(id);
        resolve(frame);
        return;
      }
      // An uncorrelated response (a fire-and-forget command's ack or its
      // error) still belongs on the event stream so clients observe failures.
      this.opts.onEvent(frame);
      return;
    }
    if (frame.type === "extension_ui_request") {
      this.opts.onExtensionUI(frame);
      return;
    }
    this.opts.onEvent(frame);
  }

  // Send a command and await its correlated response. Mints an internal id so
  // a caller-supplied id can never collide with the driver's bookkeeping; the
  // supervisor re-stamps the panel's request id onto the reply it relays.
  request(command: RpcFrame): Promise<RpcFrame> {
    if (this.stopped)
      return Promise.resolve({
        type: "response",
        success: false,
        error: "rpc child exited",
      });
    const id = `d${++this.nextId}`;
    const { promise, resolve } = Promise.withResolvers<RpcFrame>();
    this.pending.set(id, resolve);
    this.write({ ...command, id });
    return promise;
  }

  // Fire-and-forget write with no response correlation: the extension_ui
  // response back to the child, or any frame the child consumes without ack.
  send(frame: RpcFrame): void {
    this.write(frame);
  }

  private write(frame: RpcFrame): void {
    if (this.stopped) return;
    this.child.stdin?.write(`${JSON.stringify(frame)}\n`);
  }

  // Terminate the child. SIGTERM first, SIGKILL after a grace period so a
  // wedged runtime cannot keep the unit alive.
  async stop(): Promise<void> {
    if (this.stopped) return;
    this.stopped = true;
    this.child.kill("SIGTERM");
    const { promise, resolve } = Promise.withResolvers<void>();
    const grace = setTimeout(() => {
      this.child.kill("SIGKILL");
      resolve();
    }, 1000);
    this.child.on("exit", () => {
      clearTimeout(grace);
      resolve();
    });
    return promise;
  }
}
