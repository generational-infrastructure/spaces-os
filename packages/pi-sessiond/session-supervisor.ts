// The live-session registry and its lifecycle (design §5.1/§12): spawn,
// resume-from-cold, idle GC, the resident ceiling, delete. Split out of
// main.ts so the lifecycle rules — what is evictable, who gets evicted at the
// ceiling, what a child exit resets — are one module, unit-testable with a
// fake driver instead of a spawned pi child.
//
// The supervisor owns no transport and no spawn plumbing: main.ts injects a
// driver factory (argv/sandbox staging) and hooks for the event fan-out, and
// the subscriber type `C` is opaque — the supervisor only tracks membership.
import { randomUUID } from "node:crypto";
import type { SessionInfo, SessionState } from "./protocol";
import type { RpcFrame } from "./rpc-driver";
import type { SessionStore } from "./session-store";
import { SidechannelLedger } from "./sidechannel-ledger";

// The slice of RpcDriver the supervisor and the dispatcher drive. Structural
// so tests substitute a fake without spawning a child.
export interface SessionDriver {
  request(command: RpcFrame): Promise<RpcFrame>;
  send(frame: RpcFrame): void;
  stop(): Promise<void>;
}

export interface BufferedEvent {
  seq: number;
  data: string;
}

export interface Session<C> {
  id: string;
  name: string; // display label (create_session.name); "" if unnamed
  driver: SessionDriver;
  seq: number;
  subscribers: Set<C>;
  buffer: BufferedEvent[];
  busy: boolean; // mid-turn (agent_start..agent_end); never GC a busy session
  lastActivity: number; // epoch ms of last event/command; drives idle-GC + LRU
  // Open human-in-the-loop requests (extension_ui side channels, design §6).
  // Derives `parked` — blocked on a human; never GC'd.
  ledger: SidechannelLedger;
}

// The list-row shape (`kind: "sessions"`) and its state enum are wire shapes:
// they live in protocol.ts (the §12 module) and are re-exported here for the
// supervisor's own consumers.
export type { SessionInfo, SessionState };

// What the driver factory needs to spawn one pi rpc-mode child.
export interface SessionSpec {
  id: string;
  name: string;
  provider: string;
  model: string;
}

// The supervisor's wiring for a spawned child, handed to the factory so the
// driver reports back to THIS session's bookkeeping.
export interface DriverCallbacks {
  onEvent: (frame: RpcFrame) => void;
  onExtensionUI: (frame: RpcFrame) => void;
  onExit: () => void;
}

export interface SupervisorOptions<C> {
  store: SessionStore;
  // Stamped on every SessionInfo this executor reports (design §12).
  executorId: string;
  // Resident-session ceiling; 0 = unlimited.
  maxLive: number;
  // Dispose a live-idle unattached session after this long; 0 disables.
  idleTimeoutMs: number;
  // Spawns the per-session child (argv build, sandbox staging) — main.ts owns
  // that plumbing; tests inject a fake.
  createDriver: (
    spec: SessionSpec,
    callbacks: DriverCallbacks,
  ) => SessionDriver;
  // The session event stream, after lifecycle peeking — transport fan-out.
  onEvent: (session: Session<C>, frame: RpcFrame) => void;
  // extension_ui_request frames: surfaced to the panel as a side-channel.
  onSideChannel: (session: Session<C>, frame: RpcFrame) => void;
  // A list-shaping disposal happened (live → cold); broadcast the new list.
  onSessionsChanged: () => void;
}

// Safe to dispose: no attached clients, not mid-turn, not parked on a human.
export function isEvictable<C>(session: Session<C>): boolean {
  return (
    session.subscribers.size === 0 && !session.busy && !session.ledger.parked
  );
}

export class SessionSupervisor<C> {
  private readonly sessions = new Map<string, Session<C>>();

  constructor(private readonly opts: SupervisorOptions<C>) {}

  get(id: string): Session<C> | undefined {
    return this.sessions.get(id);
  }

  values(): IterableIterator<Session<C>> {
    return this.sessions.values();
  }

  // A brand-new session: mint an id, record its provider/model/name so it can
  // be reloaded from disk later, and spawn its child (which creates the jsonl).
  create(provider: string, model: string, name: string): Session<C> {
    this.enforceCeiling();
    const id = randomUUID();
    this.opts.store.create(id, { provider, model, name });
    return this.register({ id, name, provider, model });
  }

  // Reload a cold session from its committed jsonl (design §5.1: attach to
  // cold). Spawning is synchronous, so concurrent attaches can't race a
  // half-built session — the first lands it in the map before the next is
  // dispatched.
  resume(id: string): Session<C> | undefined {
    const live = this.sessions.get(id);
    if (live) return live;
    const meta = this.opts.store.readMeta(id);
    if (!meta) return undefined;
    this.opts.store.ensureWorkdir(id);
    return this.register({
      id,
      name: meta.name,
      provider: meta.provider,
      model: meta.model,
    });
  }

  // Stop a session's pi child; its committed jsonl persists, so the next
  // attach reloads it (cold). Only ever called on idle sessions. The session's
  // list state flips from "live-idle" back to "cold"; siblings learn via the
  // onSessionsChanged broadcast.
  gc(session: Session<C>): void {
    this.sessions.delete(session.id);
    void session.driver.stop();
    this.opts.onSessionsChanged();
  }

  gcIdle(): void {
    if (this.opts.idleTimeoutMs <= 0) return;
    const now = Date.now();
    for (const session of this.sessions.values()) {
      if (
        isEvictable(session) &&
        now - session.lastActivity > this.opts.idleTimeoutMs
      ) {
        this.gc(session);
      }
    }
  }

  // End the session for good — stop any live child, then remove every on-disk
  // trace. Idempotent: deleting a missing id only sweeps the disk.
  async delete(id: string): Promise<void> {
    const live = this.sessions.get(id);
    if (live) {
      this.sessions.delete(id);
      if (live.busy) live.driver.send({ type: "abort" });
      try {
        await live.driver.stop();
      } catch {
        // best-effort; we're tearing the session down regardless
      }
    }
    this.opts.store.delete(id);
  }

  // The §12 session registry: every live session with its lifecycle state,
  // plus the cold meta sidecars on disk.
  list(): SessionInfo[] {
    const out: SessionInfo[] = [];
    for (const s of this.sessions.values()) {
      out.push({
        id: s.id,
        name: s.name,
        executor: this.opts.executorId,
        state: s.ledger.parked ? "parked" : s.busy ? "live-busy" : "live-idle",
        updated: s.lastActivity,
      });
    }
    for (const id of this.opts.store.coldSessionIds()) {
      if (this.sessions.has(id)) continue;
      out.push({
        id,
        name: this.opts.store.readMeta(id)?.name ?? "",
        executor: this.opts.executorId,
        state: "cold",
        updated: this.opts.store.coldUpdatedMs(id),
      });
    }
    return out;
  }

  // Build a Session around a freshly spawned child. One path serves both a
  // fresh create and a cold reload (the child's --session-id creates the
  // session jsonl when absent and resumes it when present).
  private register(spec: SessionSpec): Session<C> {
    const session: Session<C> = {
      id: spec.id,
      name: spec.name,
      // Assigned immediately below; the driver's callbacks close over
      // `session`, so it must exist before the driver is constructed.
      driver: undefined as unknown as SessionDriver,
      seq: 0,
      subscribers: new Set(),
      buffer: [],
      busy: false,
      lastActivity: Date.now(),
      ledger: new SidechannelLedger(),
    };
    session.driver = this.opts.createDriver(spec, {
      onEvent: (frame) => {
        // Peek the turn boundary before fan-out: busy gates GC/eviction.
        if (frame.type === "agent_start") session.busy = true;
        else if (frame.type === "agent_end") session.busy = false;
        this.opts.onEvent(session, frame);
      },
      onExtensionUI: (frame) => this.opts.onSideChannel(session, frame),
      onExit: () => {
        // The child is gone: nothing is mid-turn and every open prompt is
        // moot — a dead session must never stay parked (un-evictable).
        session.busy = false;
        session.ledger.clear();
      },
    });
    this.sessions.set(spec.id, session);
    return session;
  }

  // Evict least-recently-active evictable sessions until under the ceiling.
  // Never evicts attached/busy/parked sessions — the count overshoots instead.
  private enforceCeiling(): void {
    if (this.opts.maxLive <= 0) return;
    while (this.sessions.size >= this.opts.maxLive) {
      let victim: Session<C> | undefined;
      for (const s of this.sessions.values()) {
        if (!isEvictable(s)) continue;
        if (!victim || s.lastActivity < victim.lastActivity) victim = s;
      }
      if (!victim) break;
      this.gc(victim);
    }
  }
}
