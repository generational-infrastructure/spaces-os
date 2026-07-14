// The per-session book of open extension_ui side channels (design §6):
// requests awaiting a client's answer. Split out of main.ts so the parked
// invariant is structural — parked ⟺ at least one entry is pending — instead
// of a boolean re-derived (and once mis-derived) at every call site.
//
// The ledger holds no transport: raising/answering the prompts on the wire
// stays in main.ts. It only tracks which requests are open and how to relay
// their answers to the child.

export type SidechannelRelay = (response: Record<string, unknown>) => void;

interface PendingSidechannel {
  method: string; // confirm | select | input | editor — kept for diagnostics
  relay: SidechannelRelay;
}

export class SidechannelLedger {
  private readonly sidechannels = new Map<string, PendingSidechannel>();

  // Blocked on a human: a session is parked exactly while anything is open.
  // Drives never-GC-a-parked-session and the "parked" list state.
  get parked(): boolean {
    return this.sidechannels.size > 0;
  }

  get pendingCount(): number {
    return this.sidechannels.size;
  }

  // An extension_ui request went out to the panel; `relay` forwards the
  // winning answer to the child as its extension_ui_response.
  raise(id: string, method: string, relay: SidechannelRelay): void {
    this.sidechannels.set(id, { method, relay });
  }

  // First-answer-wins: the first claim takes the relay (the caller invokes it
  // once it has told the other clients to collapse); a lost race or an
  // unknown id gets nothing.
  claim(id: string): SidechannelRelay | undefined {
    const pending = this.sidechannels.get(id);
    if (!pending) return undefined;
    this.sidechannels.delete(id);
    return pending.relay;
  }

  // The child exited: every open request is moot. Entries are dropped, never
  // relayed — there is no child left to answer to.
  clear(): void {
    this.sidechannels.clear();
  }
}
