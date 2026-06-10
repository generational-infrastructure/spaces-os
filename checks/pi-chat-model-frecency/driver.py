#!/usr/bin/env python3
"""ModelFrecency scoring/sort/persistence component test.

Drives the ModelFrecency singleton over IPC with *injected* timestamps
so the frecency ordering is fully deterministic — no sleeps, no wall
clock. Asserts the four properties the panel's model ordering relies on:

  1. Recency dominates — a model used later sorts above one used
     earlier, even at equal raw frequency.
  2. Frequency lifts among similar recency — three uses beat one when
     both happened at the same instant.
  3. Never-used models keep their backend order, below every used
     model (stable tail).
  4. The store survives a FileView reload (it persisted to disk).
  5. Default provider priority: with no frecency history, never-used
     local models sort above never-used remote ones (local on top),
     preserving backend order within each provider group.
  6. Frecency beats that default: an explicitly-picked remote model
     still outranks a never-used local one.

Plus a no-mutation guard: sortModels must return a new array and leave
its input untouched.

Headless quickshell, offscreen platform. No pi, no LLM. ~3-5s.
"""

import json
import os
import shutil
import subprocess
import sys
import time

DAY = 86400000
# A fixed, arbitrary epoch-ms base. All timestamps are injected relative
# to this so the test never reads the wall clock.
T0 = 1_700_000_000_000


def fail(msg: str) -> None:
    sys.stderr.write(f"FAIL: {msg}\n")
    sys.exit(1)


def wait_until(predicate, *, timeout_s: float, interval_s: float = 0.2) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def stage_shell(test_dir: str, plugin_dir: str, work_dir: str) -> str:
    shell_root = os.path.join(work_dir, "shell")
    os.makedirs(shell_root, exist_ok=True)
    shutil.copy2(
        os.path.join(test_dir, "shell.qml"), os.path.join(shell_root, "shell.qml")
    )
    # Stage the real Commons so the test exercises the actual
    # ModelFrecency singleton the panel ships.
    shutil.copytree(
        os.path.join(plugin_dir, "Commons"),
        os.path.join(shell_root, "Commons"),
        dirs_exist_ok=True,
    )
    now = time.time()
    for root, _dirs, files in os.walk(shell_root):
        for f in files:
            try:
                os.utime(os.path.join(root, f), (now, now))
            except OSError:
                pass
    return shell_root


def ipc_call(qs_bin: str, shell_qml: str, env: dict, *args: str) -> str:
    cmd = [qs_bin, "ipc", "-p", shell_qml, "call", "test:frecency", *args]
    out = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise RuntimeError(
            f"qs ipc call {args} failed (exit={out.returncode}):\n"
            f"stdout: {out.stdout!r}\nstderr: {out.stderr!r}"
        )
    return out.stdout.strip()


def main():
    qs_bin, test_dir, plugin_dir, work_dir = sys.argv[1:5]

    xdg_runtime = os.path.join(work_dir, "xdg_runtime")
    os.makedirs(xdg_runtime, exist_ok=True)
    os.chmod(xdg_runtime, 0o700)

    # ModelFrecency writes <HOME>/.local/state/spaces/pi/model-frecency.json;
    # FileView.writeAdapter does not create parents, so pre-create the dir.
    state_dir = os.path.join(work_dir, ".local", "state", "spaces", "pi")
    os.makedirs(state_dir, exist_ok=True)
    # Seed an empty-but-valid store so the singleton's first FileView load
    # resolves via onLoaded (which bumps loadGeneration) rather than the
    # onLoadFailed path (which is silent). That gives the driver a signal
    # to wait on before recording — otherwise the async startup load can
    # land *after* the first record() calls and clobber them. The store is
    # still empty, so every frecency assertion below is unaffected.
    with open(os.path.join(state_dir, "model-frecency.json"), "w") as f:
        f.write('{"version":1,"models":{}}')

    shell_root = stage_shell(test_dir, plugin_dir, work_dir)
    shell_qml = os.path.join(shell_root, "shell.qml")

    env = {
        "HOME": work_dir,
        "PATH": os.environ.get("PATH", "/bin:/usr/bin"),
        "XDG_RUNTIME_DIR": xdg_runtime,
        "QT_QPA_PLATFORM": "offscreen",
        "QT_PLUGIN_PATH": os.environ.get("QT_PLUGIN_PATH", ""),
        "QML2_IMPORT_PATH": os.environ.get("QML2_IMPORT_PATH", ""),
    }

    qs_stdout = open(os.path.join(work_dir, "qs.stdout.log"), "w")
    qs_stderr = open(os.path.join(work_dir, "qs.stderr.log"), "w")
    qs_proc = subprocess.Popen(
        [qs_bin, "-p", shell_qml],
        env=env,
        stdout=qs_stdout,
        stderr=qs_stderr,
    )

    def dump_logs():
        for label, name in [
            ("qs.stdout", "qs.stdout.log"),
            ("qs.stderr", "qs.stderr.log"),
        ]:
            path = os.path.join(work_dir, name)
            if os.path.isfile(path):
                sys.stderr.write(f"\n== {label} ==\n")
                sys.stderr.write(open(path).read())

    def die(msg):
        dump_logs()
        fail(msg)

    def record(key, now):
        ipc_call(qs_bin, shell_qml, env, "record", key, str(int(now)))

    def order(keys, now):
        return json.loads(
            ipc_call(qs_bin, shell_qml, env, "order", ",".join(keys), str(int(now)))
        )

    try:

        def ipc_ready():
            r = subprocess.run(
                [qs_bin, "ipc", "-p", shell_qml, "show"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            return r.returncode == 0 and "test:frecency" in r.stdout

        if not wait_until(ipc_ready, timeout_s=20):
            die("quickshell never bound the test:frecency IPC target")

        # The ModelFrecency singleton is lazily constructed on first access,
        # and its Component.onCompleted fires an *async* FileView.reload().
        # A loadGen() call constructs it; we then wait for loadGeneration to
        # bump (the seeded store hits onLoaded) so the startup read has fully
        # settled before any record() — otherwise that late read clobbers the
        # first records and ordering silently reverts to input order.
        if not wait_until(
            lambda: int(ipc_call(qs_bin, shell_qml, env, "loadGen")) >= 1,
            timeout_s=10,
        ):
            die("ModelFrecency startup FileView load never completed")

        # mostRecent on an empty store is "". PiChatBackend.newSession
        # treats that as nothing to inherit and leaves the entry on
        # pi's default. Must run before the first record().
        mr = ipc_call(qs_bin, shell_qml, env, "mostRecent")
        if mr != "":
            die(f"mostRecent on empty store: expected '', got {mr!r}")

        # (1) Recency dominates. Both used once, but b a full day later.
        record("local/a1", T0)
        record("local/b1", T0 + DAY)
        o = order(["local/a1", "local/b1"], T0 + DAY)
        if o != ["local/b1", "local/a1"]:
            die(f"recency: expected [b1, a1], got {o!r}")

        # (2) Frequency lifts among equal recency. a used 3x, b 1x, all
        # at the same instant, so recency-decay cancels and the count wins.
        record("local/a2", T0)
        record("local/a2", T0)
        record("local/a2", T0)
        record("local/b2", T0)
        o = order(["local/a2", "local/b2"], T0)
        if o != ["local/a2", "local/b2"]:
            die(f"frequency: expected [a2, b2], got {o!r}")

        # (3) Never-used models keep backend order, after the used one.
        record("local/a3", T0)
        o = order(["local/x3", "local/a3", "local/y3"], T0)
        if o != ["local/a3", "local/x3", "local/y3"]:
            die(f"never-used tail: expected [a3, x3, y3], got {o!r}")

        # (5) Default provider priority: with an EMPTY frecency history,
        # every never-used local model sorts above every never-used
        # remote one, so a fresh user sees their on-box executor first —
        # regardless of the order pi emitted them in. Within each provider
        # group the backend (input) order is preserved (stable partition).
        o = order(["openrouter/o5a", "local/l5a", "openrouter/o5b", "local/l5b"], T0)
        if o != ["local/l5a", "local/l5b", "openrouter/o5a", "openrouter/o5b"]:
            die(f"default local-first: expected locals first, got {o!r}")

        # (6) Frecency beats provider priority: an explicitly-picked remote
        # model must outrank a never-used local one. The local-first rule
        # is only a tie-break for the never-used tail, never an override of
        # a real user choice.
        record("openrouter/o6", T0)
        o = order(["local/l6", "openrouter/o6"], T0)
        if o != ["openrouter/o6", "local/l6"]:
            die(f"frecency precedence: expected used remote first, got {o!r}")

        # mostRecent is pure recency, not frecency score. local/a2 was
        # recorded 3x (score 3) but at T0. local/b1 was recorded once
        # at T0+DAY, so b1 wins. A new chat must start on what the
        # user last selected, not on their overall favourite.
        mr = ipc_call(qs_bin, shell_qml, env, "mostRecent")
        if mr != "local/b1":
            die(f"mostRecent: expected 'local/b1' (max lastUsed), got {mr!r}")

        # (no mutation) sortModels must return a new array; its input
        # stays in input order.
        probe = json.loads(
            ipc_call(
                qs_bin,
                shell_qml,
                env,
                "mutationProbe",
                ",".join(["local/x5", "local/a3", "local/y5"]),
                str(int(T0)),
            )
        )
        if probe["before"] != probe["after"]:
            die(f"sortModels mutated its input: {probe!r}")

        # (4) Persistence survives a FileView reload (state hit the disk).
        gen0 = int(ipc_call(qs_bin, shell_qml, env, "loadGen"))
        ipc_call(qs_bin, shell_qml, env, "reload")
        if not wait_until(
            lambda: int(ipc_call(qs_bin, shell_qml, env, "loadGen")) > gen0,
            timeout_s=10,
        ):
            die("FileView reload never completed (loadGeneration did not bump)")
        o = order(["local/a1", "local/b1"], T0 + DAY)
        if o != ["local/b1", "local/a1"]:
            die(f"persistence: ordering broke after reload, got {o!r}")

        # mostRecent survives the reload too. It reads the same
        # persisted lastUsed stamps the sort does.
        mr = ipc_call(qs_bin, shell_qml, env, "mostRecent")
        if mr != "local/b1":
            die(f"mostRecent after reload: expected 'local/b1', got {mr!r}")

        sys.stderr.write("PASS: frecency ordering + persistence hold\n")
    finally:
        qs_proc.terminate()
        try:
            qs_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            qs_proc.kill()


if __name__ == "__main__":
    main()
