# Executor / Client / Chat — the mental model

> The single idea everything else hangs off:
> **A chat is a long-running process on an *executor*. A *client* is just a window onto it.**

This document is the conceptual foundation for the multi-executor UX in
both clients (the Quickshell pi-chat panel and the PWA). Design decisions
in the UI kits should trace back to a rule here.

---

## 1. The three entities

| Entity | What it is | Holds the truth? | Examples |
|---|---|---|---|
| **Executor** | A self-hosted machine running the pi harness + local LLM(s) via llama-swap (optionally proxying OpenRouter). The *compute*. | **Yes** — runs the agent process, owns context window, tool execution, and the long-term memory store (sediment). | `kiwi` (home desktop), `studio` (workstation), `nas` (always-on server) |
| **Client** | A frontend that attaches to one or more executors and renders chats. The *glass*. | No — it mirrors what the executor sends; can cache for offline read. | pi-chat panel (desktop), PWA (phone/web) |
| **Chat** | One conversation = one pi session. The *work*. | Lives **on its executor**. Has a stable id that survives across clients and across moves. | "Refactor the deploy script", "Groceries" |

Relationships: a client connects to **N executors**; an executor serves
**N chats**; a chat is **homed on exactly one executor at a time** and
viewable through **N clients**.

```
  CLIENTS (glass)                 EXECUTORS (compute)
  ┌───────────────┐               ┌───────────────────────┐
  │ pi-chat panel │──┐         ┌──│ kiwi    ● online       │
  │  (desktop)    │  │ attach  │  │   ├─ chat: deploy      │
  └───────────────┘  ├────────►│  │   └─ chat: groceries   │
  ┌───────────────┐  │         │  └───────────────────────┘
  │ PWA (phone)   │──┘         └──│ studio  ○ offline       │
  └───────────────┘               │   └─ chat: 70b research │
                                  └───────────────────────┘
```

---

## 2. Two concepts the UI must never conflate

1. **Where a chat runs** — its *home executor*. A property of the **chat**. Fixed until an explicit move.
2. **What this client can reach right now** — *reachability*. A property of the **client↔executor link**, per device, live.

The phone and the desktop can have different reachability to the same
executor at the same moment (desktop on LAN, phone via relay, or phone
can't reach it at all). The chat's home doesn't change because your
phone walked out of wifi range — only the *reachability* does.

**Consequence for the UI:** a chat always shows its home executor. It
*separately* shows whether you can talk to it right now.

---

## 3. State taxonomy (drives every dot, chip, and banner)

**Executor reachability** (per client, live):
- `online` — reachable now (mint dot). Optionally `relayed` if reached off-LAN through the relay rather than direct.
- `offline` — not reachable from this client now (error/pink dot).

**Chat lifecycle** (owned by the executor, mirrored to clients):
- `idle` — waiting for you. (neutral)
- `working` — agent is thinking / streaming / running a tool. (chartreuse, animated)
- `needs you` — a confirm or prompt card is pending a human answer. (chartreuse, attention)
- `error` — last turn failed. (pink)
- `unreachable` — its home executor is offline from this client → **read-only from cache**. (dimmed)

Because a chat runs server-side, `working` and `needs you` are true even
with **no client attached** — a task fired from the QuickBar keeps going,
and a confirm can be answered later from whichever client you open.

---

## 4. Reachability & offline (the "leave the house" path)

The pitch — start on PC, continue on phone — *requires* executors be
reachable off-LAN. That's a transport concern (relay / tunnel / VPN); the
UI only ever cares about two things: **reachable or not**, and optionally
**direct vs relayed**.

Proposed offline behavior (Slack/iMessage-like, intuitive):
- A client keeps a **local mirror** of chats it has seen (the panel
  already has an in-memory mirror; sqlite keeps everything).
- If the home executor is **unreachable**, the chat is still **visible
  and scrollable** from cache, but **read-only** with a clear
  "can't reach `kiwi`" banner. Composing is disabled (or queues — see
  open question).
- When the executor comes back, the chat reconnects and catches up.

---

## 5. Starting a chat

- A new chat must resolve a **home executor** + a **model on that executor**.
- **One executor** → no choice; `+` just creates (current behavior).
- **Multiple executors** → `+` picks the executor first (defaulting to
  this client's *home* executor), then the model.
- The **model selector is scoped to the chat's executor** — you can only
  choose models that executor actually serves (already true in code).
- Each client has a **home/default executor**: the desktop panel defaults
  to the co-located local executor; the phone defaults to your primary
  remote one.

---

## 6. Moving a chat — *editing where it runs*, not a migration wizard

Because a chat **is** a process on a machine, "where it runs" is just an
editable property of the chat — like its model. So we do **not** model
moving as a special ceremony buried in a menu. Instead:

> **The "running on `kiwi`" line in the chat header IS the control.**
> Tap it → a focused **"Where this runs"** sheet that unifies *machine +
> model* in one place. Pick another reachable machine and the chat
> re-homes. Same gesture as switching models — because conceptually
> they're the same act: configuring the chat's runtime.

This is the creative reframe: moving is discoverable (it lives exactly
where "running on kiwi" already is), lightweight (edit a property, no
wizard), unified with model-switching, and it teaches the mental model in
situ ("this chat is a process on a machine — point it wherever").

Under the hood that re-home is still a **session migration** (history +
context seeded into a fresh pi process on the target, same chat id), so
the honest constraints still surface — inline, only when they bite:
- **Model may not exist on target** → the sheet shows the remap
  (`gemma3:27b → llama3.3:70b`) before you commit; you can pick another.
- **Long-term memory is per-machine** → stays on the source by default;
  a single "bring memory along" toggle copies sediment across.
- **Idle-only (v1)** → the control is disabled mid-turn with a hint to
  wait for the turn to finish.
- **Stable chat id** → every attached client re-points seamlessly.

Proactive variant (later): when the home machine is about to go offline
(PC sleeping), surface a one-tap "keep running on `nas`?" so a long task
isn't stranded.

---

## 7. Cross-device answering

Confirm/prompt cards (shell-command approvals, credential prompts) are
owned by the executor, so **any attached client can answer**; first
responder wins and the card collapses to "resolved" on the others.
This is already hinted in the panel ("answered by another mirrored
client") and becomes a headline cross-device behavior: `kiwi` wants to
run `rm -rf …`, you approve it from your phone.

---

## 8. Identity & glanceability

With 2–4 executors, **color + name + status** lets the user pattern-match
instantly ("yellow = kiwi/desktop, periwinkle = studio"). So:
- Each executor gets a **stable accent color** (from the palette:
  chartreuse / periwinkle / mint / …) + its **hostname** in mono + a
  **status dot**.
- This `ExecutorChip` is the recurring unit: on session tabs, in the chat
  header, on every PWA chat-list row, and in the fleet roster.

Naming: "executor" is precise for this NixOS / self-hosted audience; each
gets a human nickname (its hostname). (open question: surface as
"executor" vs friendlier "machine"/"host".)

---

## 9. Surfaces this model implies (where the design will express it)

1. **Fleet roster** — "my executors": name, status, active-chat count,
   models. Especially important on the phone opened remotely.
2. **Chat header executor chip** — where am I running; entry point to
   switch model or move.
3. **Chat list tagged/grouped by executor** (PWA) — the cross-device home;
   "running on `kiwi`" + *Continue here*.
4. **New-chat / Run-on picker** — choose executor → model.
5. **Move sheet** (roadmap) — pick target, resolve model + memory, show
   migration progress.

---

## 10. Resolved decisions (drive the design)

1. **Naming** — say **"machine"** in user-facing UI; keep **"executor"**
   in docs, settings, and code. The recurring chip is therefore labelled
   as a machine (hostname) to the user.
2. **Offline compose** — **hard-disable** composing when the home machine
   is unreachable. The chat is read-only from cache with a clear
   "can't reach `kiwi`" banner; no silent queue.
3. **Memory on move** — long-term memory **stays on the source machine by
   default**; the move sheet offers an explicit "Bring memory along"
   opt-in.
4. **List shape (PWA)** — **one unified chat list**, every row tagged with
   its machine chip, plus a machine filter at the top. (Designer's call.)
5. **Move timing** — **idle-only for v1** (move enabled only once the turn
   is complete).
6. **Fleet roster prominence** — **PWA prominent** (a dedicated "Machines"
   roster reachable from the top bar), **desktop minimal** (a compact
   machine switcher in the panel header that expands on demand).
   (Designer's call.)
