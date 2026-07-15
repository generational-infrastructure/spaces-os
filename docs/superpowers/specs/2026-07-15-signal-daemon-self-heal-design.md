# Signal daemon self-heal + stop-ordering cycle fix

Date: 2026-07-15
Status: draft (pending user review)

## Problem

Two defects around the `spaces-signal-cli` daemon lifecycle, root-caused
2026-07-15 from journal evidence:

1. **Torn account state, never healed.** signal-cli runs a per-account
   network check at daemon startup; on failure (`AccountCheckException:
   Closed unexpectedly`) it silently drops the account and never
   retries. Every `nixos-rebuild switch` restarts NetworkManager and
   `spaces-signal-cli` in the same instant, so the check races the
   network on every deploy — and on every boot where the daemon comes up
   before Wi-Fi associates. Observed result: account unserved for 5 days
   (Jul 10 → Jul 15), zero receives, `accounts-health.json` stuck at
   `{"store": 1, "loaded": 0}`. The MCP tool gate reports the torn state
   honestly (since commit 9aee8d40) but nothing acts on it.

2. **Shutdown ordering cycle.** `modules/nixos/spaces-integrations/lib.nix`
   gives the integration socket both `wants = extraServiceNames` and
   `after = extraServiceNames`. On stop this inverts (daemon stops after
   bridge after socket) and collides with default dependencies:
   `basic.target: Found ordering cycle ... Job
   spaces-signal-cli.service/stop deleted` (journal, Jul 10). systemd
   resolves the cycle by deleting a stop job — nondeterministic
   teardown.

## Non-goals

- Ungating the DB-read tools (`signal_threads` / `read_thread` /
  `search`) from daemon liveness. Deliberate design (decision 11);
  explicitly deselected in this session's scoping.
- Patching signal-cli (Java) to retry account loads upstream. Carried
  patch cost rejected.
- Migrating signal units onto the confined `extraServices` form
  (deferred per proton grill session 2026-07-08, decision 7).

## Approaches considered

- **A. Bridge watchdog (chosen).** The bridge already polls
  `listAccounts` every 5 min, computes store-vs-loaded, and writes
  `accounts-health.json`. Extend it: on torn state, probe network
  reachability; when reachable, restart the daemon. All required state
  already lives in the bridge; pure Python; testable in cheap checks;
  connectivity gate prevents restart-hammering while offline.
- **B. `ExecStartPost` health gate** failing the unit on torn state so
  `Restart=always` retries. Rejected: settle-window guesswork (the
  account loads then drops ~12 s after start), and a permanently dead
  (deregistered) account becomes an infinite crash loop that blocks the
  re-link flow.
- **C. Patch signal-cli** to retry loads. Rejected: forever-carried Java
  patch, rebased on every bump.

A deliberately subsumes an `ExecStartPre` network-settle wait on the
daemon unit: the watchdog covers the deploy race, the boot race, and
mid-run drops with one mechanism.

## Design

### 1. Stop-ordering cycle fix (nix)

In `modules/nixos/spaces-integrations/lib.nix`, the integration socket
unit drops `after = extraServiceNames`, keeping `wants =
extraServiceNames` and the injected reverse
`PartOf=spaces-integration-<name>.socket`.

Rationale: `wants` alone pulls the backing daemons up when the socket
starts; `after` only delays the socket's listen until the daemons are
up, which buys nothing — the MCP server dials the daemon's own socket
lazily per tool call and tolerates its absence. Removing the ordering
edge dissolves the stop-order inversion that produced the cycle.

### 2. Bridge watchdog (python)

In `packages/signal-cli/spaces_signal/bridge.py`, extend the accounts
refresher path:

- **Detection.** After each successful `listAccounts` poll, torn state
  is `store > loaded` (same computation `_write_accounts_health`
  already performs).
- **Fast re-poll.** While torn, the refresher interval drops from the
  normal ~300 s to 60 s so heal latency is bounded by ~1 min once the
  network returns, not 5.
- **Connectivity probe.** On torn detection, TCP-dial
  `chat.signal.org:443` with a short timeout (~5 s). Unreachable →
  leave the torn health file, skip restart, re-poll on the fast
  interval. This is the anti-hammering gate: no restarts while the
  network is genuinely down.
- **Restart.** Probe OK → log intent, then
  `systemctl --user --no-block restart spaces-signal-cli.service`.
  `--no-block` is load-bearing: the bridge `Requires=` the daemon, so
  the restart cascades into the bridge's own death; a blocking call
  would deadlock waiting for it. `Restart=always` (already configured,
  RestartSec=3) brings the bridge back; its fresh startup poll
  confirms the heal or re-enters the loop.
- **Cooldown.** At most one restart attempt per 10 min, persisted as
  the mtime of a marker file next to `messages.db`
  (`daemon-restart-marker`). Must be on-disk: the restart kills the
  bridge process, so in-memory state cannot carry the cooldown. Within
  cooldown → skip restart, keep fast-polling. The cooldown bounds the
  worst case (permanently deregistered account, probe passing) to one
  daemon restart per 10 min — noisy in the journal but harmless, and
  the MCP gate keeps reporting the torn state truthfully.
- **Config.** Probe host/port, fast interval, and cooldown become
  `BridgeConfig` fields with the defaults above, overridable for tests.

### 3. Unchanged surfaces

- `accounts-health.json` format and the MCP tool gate: untouched. The
  gate's "restart the daemon" message stays true — the system now also
  executes that remedy itself.
- `setupRestart` pinning (never restart the daemon post-link):
  untouched and unaffected — the watchdog only fires on `store >
  loaded`, and a freshly linked account is loaded.

### Failure modes

| Scenario | Behaviour |
|---|---|
| Deploy/boot network race | Torn detected ≤5 min, healed ≤60 s after network returns |
| Network down for hours | Fast-poll + failed probe, zero restarts |
| Account deregistered | One restart per cooldown; gate keeps reporting torn |
| Bridge itself dead | Health file goes stale (>900 s); gate already handles this |

## Testing (TDD, cheap checks)

Per-feature behaviour coverage as cheap focused tests, not
`checks/test-machine.nix` (no cross-subsystem boot dependency):

1. **Python unit tests** (`packages/signal-cli`, pattern of existing
   bridge tests): fake daemon reports torn state →
   - probe OK → restart command invoked (subprocess call injected/faked);
   - probe fails → no restart, torn health file still written;
   - marker file fresh → no restart despite probe OK;
   - marker file stale → restart, marker touched;
   - torn → refresher uses fast interval; healed → normal interval.
2. **Nix eval check** (sibling of `checks/spaces-signal-nix-eval`):
   assert the rendered `spaces-integration-signal.socket` unit has
   `Wants=` on the backing daemons and NO `After=` on them.

## Open follow-ups (recorded, not in scope)

- Confined `extraServices` migration for the signal units.
- Decision-11 revisit (DB-read tools gating on daemon liveness).
