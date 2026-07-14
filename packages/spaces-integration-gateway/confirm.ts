/**
 * The confirm command runner (docs/agent-integrations-generic-mcp-design.md §2).
 * The gateway never talks to a harness UI; it spawns a standalone confirm
 * command and waits for a verdict. Contract: the command is run with two env
 * vars — SPACES_CONFIRM_REQUEST (the request JSON) and SPACES_CONFIRM_VERDICT_FILE
 * (a path to write the verdict to) — and must write one token,
 * `once` | `session` | `deny`, to that file. Anything else — no command,
 * missing/unknown token, non-zero exit, or timeout — is `deny` (fail closed).
 */

import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ConfirmRequest, Verdict } from "./mcp-server";

const VERDICTS: Record<string, true> = {
  once: true,
  session: true,
  deny: true,
};
const DEFAULT_TIMEOUT_MS = 120000;

export function runConfirm(
  commandArgv: string[],
  req: ConfirmRequest,
  opts?: { timeoutMs?: number },
): Promise<Verdict> {
  // No confirm command ⇒ nothing can authorize an effect ⇒ fail closed.
  if (commandArgv.length === 0) return Promise.resolve("deny");

  const { promise, resolve } = Promise.withResolvers<Verdict>();
  const dir = mkdtempSync(join(tmpdir(), "spaces-confirm-"));
  const verdictFile = join(dir, "verdict");

  let settled = false;
  const finish = (v: Verdict) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    try {
      rmSync(dir, { recursive: true, force: true });
    } catch {
      // best-effort cleanup; a leftover temp dir must not change the verdict
    }
    resolve(v);
  };

  const child = spawn(commandArgv[0]!, commandArgv.slice(1), {
    stdio: "ignore",
    env: {
      ...process.env,
      SPACES_CONFIRM_REQUEST: JSON.stringify(req),
      SPACES_CONFIRM_VERDICT_FILE: verdictFile,
    },
  });

  const timer = setTimeout(() => {
    child.kill("SIGKILL");
    finish("deny");
  }, opts?.timeoutMs ?? DEFAULT_TIMEOUT_MS);

  child.on("error", () => finish("deny"));
  child.on("exit", (code) => {
    if (code !== 0) return finish("deny");
    let token = "";
    try {
      token = readFileSync(verdictFile, "utf8").trim();
    } catch {
      return finish("deny");
    }
    finish(VERDICTS[token] ? (token as Verdict) : "deny");
  });

  return promise;
}
