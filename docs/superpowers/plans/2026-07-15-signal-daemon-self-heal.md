# Signal Daemon Self-Heal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bridge watchdog that auto-restarts `spaces-signal-cli` when signal-cli's startup network check drops the linked account (torn state), plus removal of the socket `After=` edge that produced the shutdown ordering cycle.

**Architecture:** The bridge (`spaces-signal-bridge.service`, `packages/signal-cli/spaces_signal/bridge.py`) already detects torn state (`store > loaded`) in its accounts-refresher poll. This plan adds the reaction: network probe → cooldown check → `systemctl --user --no-block restart spaces-signal-cli.service`, with a 60 s fast re-poll while torn. The nix side drops `after = extraServiceNames` from the integration socket unit in `modules/nixos/spaces-integrations/lib.nix`.

**Tech Stack:** Python 3.13 (stdlib only — matches existing bridge), nix eval checks, pytest via `nix build .#signal-cli` checkPhase.

**Spec:** `docs/superpowers/specs/2026-07-15-signal-daemon-self-heal-design.md`

## Global Constraints

- Version control is `jj`, top-level agent only. Isolated subagents run NO `jj`/`git` — the harness captures their worktrees.
- No new systemd units. Watchdog lives inside the existing bridge process.
- `accounts-health.json` format unchanged: `{"store", "loaded", "updated"}`.
- Defaults (from spec, verbatim): probe `chat.signal.org:443`, probe timeout 5 s, cooldown 600 s, torn re-poll 60 s, normal poll 300 s.
- Restart command exactly: `systemctl --user --no-block restart spaces-signal-cli.service` (`--no-block` is load-bearing: the bridge `Requires=` the daemon, a blocking restart deadlocks on its own death).
- Cooldown marker: `<db_path dir>/daemon-restart-marker`, cooldown = mtime age. Must be on-disk (the restart kills the bridge process).
- Tests run via `nix build .#signal-cli` (pytest checkPhase covers `test_bridge.py`); the eval check via `nix build .#checks.x86_64-linux.spaces-signal-nix-eval`. Do NOT run project-wide suites.
- Do NOT touch `checks/test-machine.nix`.

## File Structure

- Modify: `packages/signal-cli/spaces_signal/bridge.py` — `BridgeConfig` fields, watchdog methods, refresher interval.
- Modify: `packages/signal-cli/test_bridge.py` — new `WatchdogTest` class reusing `FakeSignalDaemon`.
- Modify: `modules/nixos/spaces-integrations/lib.nix:422-428` — drop `after`.
- Modify: `checks/spaces-signal-nix-eval/default.nix` — socket-unit assertions (Wants= present, After= absent). This is the module-contract check; extending it is the right home (not a new check, not test-machine.nix).

---

### Task 1: Watchdog core — torn detection triggers restart

**Files:**
- Modify: `packages/signal-cli/spaces_signal/bridge.py`
- Test: `packages/signal-cli/test_bridge.py`

**Interfaces:**
- Produces: `BridgeConfig` fields `probe_host: str = "chat.signal.org"`, `probe_port: int = 443`, `probe_timeout_seconds: float = 5.0`, `restart_cooldown_seconds: float = 600.0`; `Bridge.__init__` kwargs `network_probe: Callable[[], bool] | None = None`, `restart_daemon: Callable[[], None] | None = None`, `torn_refresh_seconds: float = 60.0`; internal `Bridge._maybe_heal(store: int, loaded: int) -> None`, `Bridge._torn: bool`.
- Consumes: existing `_refresh_accounts` / `_store_account_count` / `_write_accounts_health` in `bridge.py`, existing `FakeSignalDaemon` + store-file fixture pattern in `test_bridge.py` (see the `accounts_store_path` test around line 638 for the store JSON shape: `{"accounts": [ ... ]}`).

- [ ] **Step 1: Write the failing tests**

Append to `packages/signal-cli/test_bridge.py` (imports already present: `json`, `tempfile`, `threading`, `time`, `unittest`, `Path`, `bridge_mod`, `FakeSignalDaemon`):

```python
# ── watchdog: torn-state self-heal ──────────────────────────────────
# signal-cli's per-account startup network check silently drops linked
# accounts (never retried). The bridge already computes store-vs-loaded;
# these tests pin the new reaction: probe network, respect an on-disk
# restart cooldown, restart the daemon. Probe + restart are injected —
# no real network, no real systemctl.


class WatchdogTest(unittest.TestCase):
    def _make_bridge(
        self,
        *,
        store_accounts: int,
        daemon_accounts: list[dict],
        probe_ok: bool,
        marker_age_seconds: float | None = None,
    ) -> tuple[bridge_mod.Bridge, list[str]]:
        base = Path(tempfile.mkdtemp(prefix="watchdog-test-"))
        daemon = FakeSignalDaemon(str(base / "signal.sock"))
        daemon.accounts = daemon_accounts
        self.addCleanup(daemon.stop)

        store_path = base / "data" / "accounts.json"
        store_path.parent.mkdir(parents=True)
        store_path.write_text(
            json.dumps(
                {
                    "accounts": [
                        {"number": f"+49{i:010d}", "uuid": f"uuid-{i}"}
                        for i in range(store_accounts)
                    ]
                }
            )
        )

        db_path = base / "messages.db"
        if marker_age_seconds is not None:
            marker = db_path.parent / "daemon-restart-marker"
            marker.touch()
            past = time.time() - marker_age_seconds
            os.utime(marker, (past, past))

        events: list[str] = []
        bridge = bridge_mod.Bridge(
            bridge_mod.BridgeConfig(
                db_path=db_path,
                daemon_socket=daemon.sock_path,
                accounts_store_path=store_path,
            ),
            accounts_refresh_seconds=60.0,
            network_probe=lambda: events.append("probe") or probe_ok,
            restart_daemon=lambda: events.append("restart"),
        )
        bridge.start()
        self.addCleanup(bridge.stop)
        return bridge, events

    def test_torn_state_with_network_restarts_daemon(self):
        # store=1, loaded=0: exactly the deploy-race torn state. Network
        # probe passes -> the bridge must fire the daemon restart.
        bridge, events = self._make_bridge(
            store_accounts=1, daemon_accounts=[], probe_ok=True
        )
        self.assertIn("restart", events)
        # Marker file written so the cooldown survives the bridge's own
        # death in the restart cascade.
        marker = bridge.config.db_path.parent / "daemon-restart-marker"
        self.assertTrue(marker.exists())

    def test_healthy_state_never_probes_or_restarts(self):
        bridge, events = self._make_bridge(
            store_accounts=1,
            daemon_accounts=[{"number": "+490000000000", "uuid": "uuid-0"}],
            probe_ok=True,
        )
        self.assertEqual(events, [])

    def test_never_linked_never_probes_or_restarts(self):
        # store=0, loaded=0: pre-onboarding. Watchdog must stay silent.
        bridge, events = self._make_bridge(
            store_accounts=0, daemon_accounts=[], probe_ok=True
        )
        self.assertEqual(events, [])
```

- [ ] **Step 2: Run tests to verify they fail for the right reason**

```
cd packages/signal-cli && python -m pytest test_bridge.py -k WatchdogTest -x -q
```

(Devshell is auto-loaded; pytest is on PATH.)

Expected: `TypeError: Bridge.__init__() got an unexpected keyword argument 'network_probe'` — NOT a collection error. A `NameError` on `os` means the test file needs `import os` (it already has it at line 14).

- [ ] **Step 3: Implement the watchdog core**

In `packages/signal-cli/spaces_signal/bridge.py`:

Add to the import block (verified: bridge.py currently imports `json`, `logging`, `os`, `sqlite3`, `threading` — no `socket`, `subprocess`, or `time`). Insert alphabetically:

```python
import socket
import subprocess
import time
```

Extend `BridgeConfig`:

```python
@dataclass
class BridgeConfig:
    db_path: Path
    daemon_socket: str
    # signal-cli's on-disk account store (data/accounts.json). Counted into
    # the exported accounts-health.json so the MCP tool gate can tell "never
    # linked" from "linked but the daemon dropped the account at startup".
    # None/absent/unparseable counts as 0.
    accounts_store_path: Path | None = None
    # Watchdog: signal-cli's per-account startup network check silently
    # drops linked accounts and never retries (torn state: store > loaded).
    # The bridge heals it — probe reachability, then restart the daemon.
    probe_host: str = "chat.signal.org"
    probe_port: int = 443
    probe_timeout_seconds: float = 5.0
    # At most one restart attempt per cooldown, persisted as the mtime of
    # daemon-restart-marker next to messages.db (the restart cascades into
    # the bridge's own death, so memory cannot carry it).
    restart_cooldown_seconds: float = 600.0
```

Extend `Bridge.__init__` signature (after `expire_interval_seconds`):

```python
        torn_refresh_seconds: float = 60.0,
        network_probe: Callable[[], bool] | None = None,
        restart_daemon: Callable[[], None] | None = None,
```

and in the body (after `self._expire_interval_seconds = ...`):

```python
        self._torn_refresh_seconds = torn_refresh_seconds
        self._network_probe = network_probe or self._default_network_probe
        self._restart_daemon = restart_daemon or self._default_restart_daemon
        self._torn = False
```

Add methods (after `_write_accounts_health`):

```python
    # ── torn-state watchdog ─────────────────────────────────────────

    def _default_network_probe(self) -> bool:
        """TCP-dial the Signal endpoint. The anti-hammering gate: while
        the network is genuinely down a daemon restart would just re-run
        signal-cli's failing account check and re-drop the account.
        """
        try:
            with socket.create_connection(
                (self.config.probe_host, self.config.probe_port),
                timeout=self.config.probe_timeout_seconds,
            ):
                return True
        except OSError:
            return False

    def _default_restart_daemon(self) -> None:
        # --no-block is load-bearing: this bridge Requires= the daemon, so
        # the restart cascades into our own death; a blocking call would
        # deadlock waiting for it. Restart=always revives us and the fresh
        # startup poll confirms the heal.
        subprocess.run(
            [
                "systemctl",
                "--user",
                "--no-block",
                "restart",
                "spaces-signal-cli.service",
            ],
            check=False,
        )

    @property
    def _restart_marker(self) -> Path:
        return self.config.db_path.parent / "daemon-restart-marker"

    def _restart_cooldown_active(self) -> bool:
        try:
            age = time.time() - self._restart_marker.stat().st_mtime
        except OSError:
            return False
        return age < self.config.restart_cooldown_seconds

    def _maybe_heal(self, store: int, loaded: int) -> None:
        """store > loaded means signal-cli's startup network check dropped
        a linked account (it never retries). Heal: probe, cooldown-gate,
        restart the daemon. Worst case (account deregistered, probe green)
        is one restart per cooldown — the MCP gate keeps reporting torn.
        """
        self._torn = store > loaded
        if not self._torn:
            return
        if not self._network_probe():
            log.warning(
                "torn account state (store=%d loaded=%d), network unreachable"
                " — re-polling in %.0fs",
                store,
                loaded,
                self._torn_refresh_seconds,
            )
            return
        if self._restart_cooldown_active():
            log.info(
                "torn account state (store=%d loaded=%d), restart cooldown"
                " active — skipping",
                store,
                loaded,
            )
            return
        try:
            self._restart_marker.touch()
        except OSError as exc:
            log.warning("restart marker write failed: %s", exc)
        log.warning(
            "torn account state (store=%d loaded=%d), network reachable"
            " — restarting spaces-signal-cli (expect our own restart in the"
            " cascade)",
            store,
            loaded,
        )
        self._restart_daemon()
```

Wire into `_refresh_accounts` — replace the tail (`self._write_accounts_health(len(accounts))`) with:

```python
        store = self._store_account_count()
        self._write_accounts_health(store=store, loaded=len(accounts))
        self._maybe_heal(store, len(accounts))
```

and change `_write_accounts_health` to take both counts (it currently recomputes store itself):

```python
    def _write_accounts_health(self, *, store: int, loaded: int) -> None:
```

with the body's `"store": self._store_account_count(),` becoming `"store": store,`. Docstring stays.

- [ ] **Step 4: Run tests to verify they pass**

```
cd packages/signal-cli && python -m pytest test_bridge.py -k WatchdogTest -x -q
```

Expected: 3 passed. Then the full bridge file suite (guards the `_write_accounts_health` signature change):

```
python -m pytest test_bridge.py -q
```

Expected: all pass.

- [ ] **Step 5: Commit (top-level agent only)**

`jj describe -m "signal bridge: watchdog restarts daemon on torn account state"` — or if executing via isolated subagents, the harness captures; do nothing.

---

### Task 2: Watchdog gates — probe failure and cooldown

**Files:**
- Modify: `packages/signal-cli/test_bridge.py` (tests only; implementation landed in Task 1 — these tests pin the gates' behaviour independently)

**Interfaces:**
- Consumes: `WatchdogTest._make_bridge` from Task 1 (same file, same class).

- [ ] **Step 1: Write the tests**

Append inside `WatchdogTest`:

```python
    def test_probe_failure_blocks_restart(self):
        # Network down: restarting would just re-run the failing account
        # check. Probe must fire, restart must not.
        bridge, events = self._make_bridge(
            store_accounts=1, daemon_accounts=[], probe_ok=False
        )
        self.assertIn("probe", events)
        self.assertNotIn("restart", events)
        # No marker: a blocked attempt must not consume the cooldown.
        marker = bridge.config.db_path.parent / "daemon-restart-marker"
        self.assertFalse(marker.exists())

    def test_fresh_marker_blocks_restart(self):
        # A restart fired <cooldown ago (marker mtime young): skip, even
        # with the network up — bounds the deregistered-account worst case
        # to one restart per cooldown.
        bridge, events = self._make_bridge(
            store_accounts=1,
            daemon_accounts=[],
            probe_ok=True,
            marker_age_seconds=10.0,
        )
        self.assertNotIn("restart", events)

    def test_stale_marker_allows_restart(self):
        bridge, events = self._make_bridge(
            store_accounts=1,
            daemon_accounts=[],
            probe_ok=True,
            marker_age_seconds=601.0,
        )
        self.assertIn("restart", events)
```

- [ ] **Step 2: Run and verify all three pass immediately**

```
cd packages/signal-cli && python -m pytest test_bridge.py -k WatchdogTest -q
```

Expected: 6 passed. These pass against Task 1's implementation — they are regression pins, not red-green (the logic is one unit; splitting the implementation to force reds here would be artificial). If any FAILS, the Task 1 implementation is wrong: fix `_maybe_heal` ordering (probe before cooldown before marker-touch before restart) until green.

- [ ] **Step 3: Commit**

`jj` describe covers Task 1+2 together if executed inline; isolated subagents: nothing.

---

### Task 3: Fast re-poll while torn

**Files:**
- Modify: `packages/signal-cli/spaces_signal/bridge.py`
- Test: `packages/signal-cli/test_bridge.py`

**Interfaces:**
- Produces: `Bridge._refresh_interval() -> float` (used by `_run_accounts_refresher`).
- Consumes: `Bridge._torn` from Task 1.

- [ ] **Step 1: Write the failing test**

Append inside `WatchdogTest`:

```python
    def test_refresh_interval_drops_while_torn(self):
        # Heal latency must be bounded by the torn interval (60s), not the
        # normal poll (300s): once the network returns, the next poll's
        # probe passes and the restart fires within ~1 min.
        bridge, _ = self._make_bridge(
            store_accounts=1, daemon_accounts=[], probe_ok=False
        )
        self.assertTrue(bridge._torn)
        self.assertEqual(bridge._refresh_interval(), 60.0)

    def test_refresh_interval_normal_when_healthy(self):
        bridge, _ = self._make_bridge(
            store_accounts=1,
            daemon_accounts=[{"number": "+490000000000", "uuid": "uuid-0"}],
            probe_ok=True,
        )
        self.assertFalse(bridge._torn)
        self.assertEqual(bridge._refresh_interval(), 60.0)  # ctor value
```

Note: `_make_bridge` passes `accounts_refresh_seconds=60.0`, so the healthy case also reads 60.0. To make the two cases distinguishable, change `_make_bridge`'s ctor call to `accounts_refresh_seconds=300.0, torn_refresh_seconds=60.0` and assert `300.0` in the healthy test:

```python
        self.assertEqual(bridge._refresh_interval(), 300.0)
```

(Existing WatchdogTest cases don't depend on the poll interval — `start()` triggers the first refresh synchronously — so the change is safe within this class.)

- [ ] **Step 2: Run to verify failure**

```
cd packages/signal-cli && python -m pytest test_bridge.py -k refresh_interval -q
```

Expected: FAIL with `AttributeError: 'Bridge' object has no attribute '_refresh_interval'`.

- [ ] **Step 3: Implement**

In `bridge.py`, add next to `_run_accounts_refresher`:

```python
    def _refresh_interval(self) -> float:
        # Torn -> fast re-poll so the heal fires within ~1 min of the
        # network returning, instead of the normal 5-min cadence.
        return self._torn_refresh_seconds if self._torn else self._accounts_refresh_seconds
```

and change `_run_accounts_refresher`:

```python
    def _run_accounts_refresher(self) -> None:
        while not self._stop.wait(self._refresh_interval()):
            self._refresh_accounts()
```

- [ ] **Step 4: Run the whole file**

```
cd packages/signal-cli && python -m pytest test_bridge.py -q
```

Expected: all pass. Also build the package check once:

```
nix build .#signal-cli
```

Expected: builds green (pytest checkPhase runs test_db.py + test_bridge.py).

- [ ] **Step 5: Commit**

`jj describe` (inline) or nothing (isolated).

---

### Task 4: Drop socket `After=` on backing daemons (ordering-cycle fix)

**Files:**
- Modify: `modules/nixos/spaces-integrations/lib.nix:417-428` (the `socketUnit` binding)
- Test: `checks/spaces-signal-nix-eval/default.nix`

**Interfaces:**
- Consumes: `enabledSystem.config.systemd.user.sockets.spaces-integration-signal` (exists in the check's eval already — same `enabledSystem`).
- Produces: socket unit with `wants` on backing daemons, no `after` on them.

- [ ] **Step 1: Write the failing eval assertions**

In `checks/spaces-signal-nix-eval/default.nix`, add to the `let` block (after `bridge = ...`, line 92):

```nix
  integSocket = enabledSystem.config.systemd.user.sockets.spaces-integration-signal;
```

Add to the `runCommand` attrs (after `bridgeCondition`, ~line 114):

```nix
    socketWants = lib.concatStringsSep " " (integSocket.wants or [ ]);
    socketAfter = lib.concatStringsSep " " (integSocket.after or [ ]);
```

Add a new assertion section to the script (after section 3, the PartOf checks, ~line 200):

```sh
    # ── 3b. socket pulls daemons via Wants= WITHOUT After= ────────────
    # After= on the backing daemons inverts on shutdown (daemon stops
    # after bridge after socket) and collided with default deps into an
    # ordering cycle (`Job spaces-signal-cli.service/stop deleted`,
    # journal 2026-07-10). Wants= alone is sufficient: the MCP server
    # dials the daemon socket lazily per tool call.
    for svc in spaces-signal-cli.service spaces-signal-bridge.service; do
      case " $socketWants " in
        *" $svc "*) ;;
        *) fail "integration socket must Wants=$svc, got '$socketWants'" ;;
      esac
      case " $socketAfter " in
        *" $svc "*) fail "integration socket must NOT be After=$svc (shutdown ordering cycle), got '$socketAfter'" ;;
        *) ;;
      esac
    done
```

Also update the check's header comment, line 14: `pulled in by the Signal integration socket (Wants=/After=)` → `pulled in by the Signal integration socket (Wants=, deliberately no After= — shutdown ordering cycle)`.

- [ ] **Step 2: Run the check to verify it fails**

```
nix build .#checks.x86_64-linux.spaces-signal-nix-eval -L
```

Expected: FAIL with `integration socket must NOT be After=spaces-signal-cli.service ...` — proves the assertion reaches the real rendered unit.

- [ ] **Step 3: Fix lib.nix**

In `modules/nixos/spaces-integrations/lib.nix`, the `socketUnit` binding (lines 417-428) becomes:

```nix
      socketUnit =
        mkSocketUnit {
          path = socketPath;
          description = "Spaces integration socket: ${manifest.description}";
        }
        // lib.optionalAttrs (extraServiceNames != [ ]) {
          # Starting this socket pulls in the integration's backing daemons; the
          # spaces-integrations module injects the reverse PartOf onto each so a
          # GUI disable (socket stop) tears them down too.
          #
          # Wants= WITHOUT After=: an After= edge here inverts on shutdown
          # (daemon stops after bridge after socket) and collides with default
          # dependencies into an ordering cycle — systemd resolved it by
          # DELETING the daemon's stop job (journal 2026-07-10). Ordering buys
          # nothing anyway: the MCP server dials the daemon's own socket
          # lazily per tool call and tolerates its absence.
          wants = extraServiceNames;
        };
```

(Only change: `after = extraServiceNames;` removed, comment extended.)

- [ ] **Step 4: Run the check to verify it passes**

```
nix build .#checks.x86_64-linux.spaces-signal-nix-eval -L
```

Expected: `OK`, build green.

- [ ] **Step 5: Commit**

`jj describe -m "spaces-integrations: drop socket After= on backing daemons (stop-ordering cycle)"` (inline) or nothing (isolated).

---

### Task 5: Final verification + describe

- [ ] **Step 1: Targeted builds only** (no project-wide suite):

```
nix build .#signal-cli .#checks.x86_64-linux.spaces-signal-nix-eval -L
```

Expected: both green.

- [ ] **Step 2 (top-level agent):** `git for-each-ref refs/omp/task` — adopt any parked subagent refs per global workflow; then final `jj describe -m "signal: self-heal torn account state + fix integration socket stop-ordering cycle"`.

## Self-Review Notes

- Spec coverage: torn detection/probe/cooldown/fast-poll (Tasks 1-3), cycle fix + eval check (Task 4), health-file format untouched (Task 1 keeps keys), setupRestart untouched (no task modifies defaults.nix) — all spec sections mapped.
- Type consistency: `_make_bridge` returns `(Bridge, list[str])` everywhere; `_write_accounts_health(*, store, loaded)` signature change is confined to Task 1 and its only caller `_refresh_accounts`.
- `socket` import: bridge.py's import block must be checked in Task 1 Step 3 — `socket.create_connection` needs it; `time` likewise.
