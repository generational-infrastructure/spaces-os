/**
 * What the supervisor still needs from the (now standalone) integrations system
 * (docs/agent-integrations-generic-mcp-design.md): the enabled set and the
 * per-session file-exchange shared-dir grant. Discovery, tool aggregation, and
 * per-call approval moved out of the supervisor into
 * packages/spaces-integration-gateway — the agent reaches them over MCP, not the
 * rpc pipe. The only integration concern left here is the agent's OWN sandbox:
 * granting each enabled integration's shared dir into the session Landlock
 * policy so file exchange (clone_to_workspace → the agent edits the tree) works.
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

// Integration names build shared-dir paths; only plain idents.
const NAME_RE = /^[a-zA-Z0-9_-]+$/;

// Enabled integrations from the broker's enabled.json
// (`{ integrations: { <name>: { enabled: true } } }`) — names only. Any
// read/parse failure ⇒ none (never throws — a broken file must not block
// session creation).
export function loadEnabled(enabledPath: string): string[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(enabledPath, "utf8"));
  } catch (err) {
    // A missing enabled.json = no integrations configured (the common case);
    // only a malformed/unreadable file is worth logging.
    if ((err as NodeJS.ErrnoException).code !== "ENOENT") {
      console.error(`integrations: cannot read ${enabledPath}: ${err}`);
    }
    return [];
  }
  if (!isRecord(parsed) || !isRecord(parsed.integrations)) return [];
  const names: string[] = [];
  for (const [name, state] of Object.entries(parsed.integrations)) {
    if (!isRecord(state) || state.enabled !== true) continue;
    if (!NAME_RE.test(name)) {
      console.error(
        `integrations: skipping bad integration name ${JSON.stringify(name)}`,
      );
      continue;
    }
    names.push(name);
  }
  return names;
}

// The per-integration file-exchange dirs to fold into the agent session's
// Landlock rw allowlist (design §9.4 step 6): one <sharedBase>/<name> per
// enabled integration — the SAME dir the integration unit grants itself rw, so
// clone_to_workspace populates it and the agent edits the tree with its native
// file tools. Empty base, empty enabled path, or no integrations ⇒ none, so the
// grant appears only when an integration is enabled.
export function sessionSharedDirs(
  enabledPath: string,
  sharedBase: string,
): string[] {
  if (!sharedBase || !enabledPath) return [];
  return loadEnabled(enabledPath).map((name) => join(sharedBase, name));
}
