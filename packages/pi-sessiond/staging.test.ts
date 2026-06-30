// stageFile: template staging must survive daemon restarts.
//
// The templates come from the Nix store (mode 0444). A naive copy
// preserves that mode, so the second staging onto the leftover
// read-only file fails EACCES and the daemon crash-loops (observed
// in production: pi-sessiond restart counter 88). The contract:
// staging is idempotent, and re-staging replaces stale content even
// over pre-existing read-only residue.
import { expect, test } from "bun:test";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
  chmodSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { stageFile } from "./staging";

// A store-like template: read-only, as builtins in /nix/store are.
function makeTemplate(dir: string, name: string, content: string): string {
  const p = join(dir, name);
  writeFileSync(p, content);
  chmodSync(p, 0o444);
  return p;
}

test("staging twice from a read-only template succeeds (daemon restart)", () => {
  const dir = mkdtempSync(join(tmpdir(), "staging-"));
  const src = makeTemplate(dir, "settings.json", '{"a":1}');
  // mimic main.ts: agent dir exists before staging (mkdirSync recursive
  // happens earlier in the daemon)
  const agentDir = join(dir, "agent");
  mkdirSync(agentDir, { recursive: true });
  const dest = join(agentDir, "settings.json");
  stageFile(src, dest);
  stageFile(src, dest);
  expect(readFileSync(dest, "utf8")).toBe('{"a":1}');
});

test("re-staging replaces stale read-only residue from old builds", () => {
  const dir = mkdtempSync(join(tmpdir(), "staging-"));
  const dest = join(dir, "settings.json");
  // Residue an old copyFileSync-based daemon left behind: 0444, stale.
  writeFileSync(dest, '{"old":true}');
  chmodSync(dest, 0o444);
  const src = makeTemplate(dir, "template.json", '{"new":true}');
  stageFile(src, dest);
  expect(readFileSync(dest, "utf8")).toBe('{"new":true}');
});
