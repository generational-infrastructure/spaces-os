// On-disk session state under the daemon's state dir. Split out of main.ts so
// the layout contract — where a session's dir/workspace/agent-dir/tmp/meta
// sidecar live, what "cold" means, and what a delete must remove — is one
// module, unit-testable against a tmpdir instead of the daemon's STATE_DIR.
//
// Layout (all under the base dir passed to the constructor):
//   sessions/<id>/           committed jsonl + landlock.json + agent/ + tmp/
//   sessions/<id>.meta.json  daemon bookkeeping sidecar (SIBLING of the
//                            session dir, so pi never sees it)
//   workspaces/<id>/         the session's working tree
import {
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";

// Persisted per-session metadata so a disposed/cold session can be reloaded
// with the right provider/model (and its display name) after GC or a daemon
// restart.
export interface SessionMeta {
  provider: string;
  model: string;
  name: string;
}

// A session id is always a randomUUID() we minted. Validating it before it
// builds filesystem paths closes a path-traversal hole on attach.sessionId.
const SESSION_ID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export function isSessionId(value: string): boolean {
  return SESSION_ID_RE.test(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
function asString(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

export class SessionStore {
  constructor(private readonly baseDir: string) {
    mkdirSync(`${baseDir}/sessions`, { recursive: true });
  }

  sessionDirOf(id: string): string {
    return `${this.baseDir}/sessions/${id}`;
  }
  workdirOf(id: string): string {
    return `${this.baseDir}/workspaces/${id}`;
  }
  // Each Landlock session's own writable agent dir (HOME / PI_CODING_AGENT_DIR),
  // nested under its session dir so the one rw grant on the session dir covers
  // it and concurrent instances never share a writable HOME.
  agentDirOf(id: string): string {
    return `${this.sessionDirOf(id)}/agent`;
  }
  // Each session's private TMPDIR, nested under its session dir (so the one rw
  // grant on sessions/<id> covers it). The host's shared /tmp is absent from
  // the allowlist and thus denied; tools that ignore $TMPDIR and write /tmp/...
  // would otherwise EACCES, so point them here instead (design §5.1).
  tmpDirOf(id: string): string {
    return `${this.sessionDirOf(id)}/tmp`;
  }
  metaPathOf(id: string): string {
    return `${this.baseDir}/sessions/${id}.meta.json`;
  }

  // Lay out a brand-new session: its dir, its workspace, and the meta sidecar
  // that lets a cold reload pick the right provider/model/name later.
  create(id: string, meta: SessionMeta): void {
    mkdirSync(this.sessionDirOf(id), { recursive: true });
    mkdirSync(this.workdirOf(id), { recursive: true });
    this.writeMeta(id, meta);
  }

  // A cold resume re-creates the workspace if it was dropped from disk.
  ensureWorkdir(id: string): void {
    mkdirSync(this.workdirOf(id), { recursive: true });
  }

  writeMeta(id: string, meta: SessionMeta): void {
    writeFileSync(this.metaPathOf(id), JSON.stringify(meta));
  }

  readMeta(id: string): SessionMeta | undefined {
    let parsed: unknown;
    try {
      parsed = JSON.parse(readFileSync(this.metaPathOf(id), "utf8"));
    } catch {
      return undefined;
    }
    if (!isRecord(parsed)) return undefined;
    const provider = asString(parsed.provider);
    const model = asString(parsed.model);
    if (provider === undefined || model === undefined) return undefined;
    return { provider, model, name: asString(parsed.name) ?? "" };
  }

  // Cold sessions: the meta sidecars on disk. The caller subtracts its live
  // set — the store knows nothing about spawned children.
  coldSessionIds(): string[] {
    try {
      return readdirSync(`${this.baseDir}/sessions`)
        .filter((f) => f.endsWith(".meta.json"))
        .map((f) => f.slice(0, -".meta.json".length))
        .filter(isSessionId);
    } catch {
      return [];
    }
  }

  coldUpdatedMs(id: string): number {
    try {
      return statSync(this.sessionDirOf(id)).mtimeMs;
    } catch {
      return 0;
    }
  }

  // Remove every on-disk trace: session dir (jsonl, agent dir, tmp), meta
  // sidecar, workspace. Each rm guards individually so a partial state still
  // cleans up whatever else is on disk. `force` swallows ENOENT — deleting a
  // missing session is a no-op.
  delete(id: string): void {
    try {
      rmSync(this.sessionDirOf(id), { recursive: true, force: true });
    } catch {
      // ignore
    }
    try {
      rmSync(this.metaPathOf(id), { force: true });
    } catch {
      // ignore
    }
    try {
      rmSync(this.workdirOf(id), { recursive: true, force: true });
    } catch {
      // ignore
    }
  }
}
