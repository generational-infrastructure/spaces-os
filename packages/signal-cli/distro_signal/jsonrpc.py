"""Line-delimited JSON-RPC 2.0 over a unix socket.

signal-cli's daemon speaks newline-terminated JSON-RPC. A request is
one line in, one line out; the server may push additional lines
(notifications — no `id` field) on the same socket once we've
subscribed via `subscribeReceive`.

The client owns a background reader thread that dispatches both
responses (back to the matching `call()` waiter via a per-request
event) and server-initiated notifications (to the optional handler
registered at construction time). This is the only sane shape for
JSON-RPC over a long-lived connection: `call()` and `subscribeReceive`
share one socket, so issuing a call from the same thread that would
read the response trivially deadlocks.
"""

from __future__ import annotations

import json
import socket
import threading
from typing import Callable

NotificationHandler = Callable[[str, object], None]


class JsonRpcError(RuntimeError):
    def __init__(self, code: int, message: str, data: object = None) -> None:
        super().__init__(f"jsonrpc error {code}: {message}")
        self.code = code
        self.message = message
        self.data = data


class JsonRpcClient:
    """Blocking JSON-RPC 2.0 client over a unix socket with an
    auto-started background reader.

    Construct with an optional `on_notification(method, params)`
    handler that fires for every server-initiated message. The reader
    thread blocks on the socket; `close()` shuts the socket down,
    which unblocks the reader and ends `wait_closed()`.
    """

    def __init__(
        self,
        sock_path: str,
        *,
        on_notification: NotificationHandler | None = None,
        on_close: Callable[[], None] | None = None,
    ) -> None:
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.connect(sock_path)
        self._reader = self._sock.makefile("r", encoding="utf-8", newline="\n")
        self._write_lock = threading.Lock()

        self._next_id = 1
        self._id_lock = threading.Lock()

        self._pending: dict[int, threading.Event] = {}
        self._results: dict[int, dict] = {}
        self._pending_lock = threading.Lock()

        self._closed = threading.Event()
        self._on_notification = on_notification
        self._on_close = on_close

        self._reader_thread = threading.Thread(
            target=self._run_reader, name="jsonrpc-reader", daemon=True
        )
        self._reader_thread.start()

    def close(self) -> None:
        if self._closed.is_set():
            return
        self._closed.set()
        try:
            self._sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self._sock.close()
        except OSError:
            pass
        # Unblock any in-flight call() waiters so callers don't hang
        # waiting for a response that will never arrive.
        with self._pending_lock:
            for evt in self._pending.values():
                evt.set()

    def wait_closed(self, timeout: float | None = None) -> bool:
        """Block until the reader has exited (socket closed by either
        side). Returns True iff the reader finished within `timeout`."""
        self._reader_thread.join(timeout)
        return not self._reader_thread.is_alive()

    def is_closed(self) -> bool:
        return self._closed.is_set()

    def _alloc_id(self) -> int:
        with self._id_lock:
            n = self._next_id
            self._next_id += 1
            return n

    def _send_line(self, payload: dict) -> None:
        if self._closed.is_set():
            raise OSError("jsonrpc client is closed")
        line = json.dumps(payload, separators=(",", ":")) + "\n"
        data = line.encode("utf-8")
        with self._write_lock:
            self._sock.sendall(data)

    def call(
        self,
        method: str,
        params: object | None = None,
        *,
        timeout: float = 10.0,
    ) -> object:
        req_id = self._alloc_id()
        evt = threading.Event()
        with self._pending_lock:
            self._pending[req_id] = evt
        try:
            req: dict = {"jsonrpc": "2.0", "id": req_id, "method": method}
            if params is not None:
                req["params"] = params
            self._send_line(req)
            if not evt.wait(timeout):
                raise TimeoutError(
                    f"jsonrpc call {method!r} timed out after {timeout}s"
                )
            with self._pending_lock:
                resp = self._results.pop(req_id, None)
            if resp is None:
                # Closed under us — close() sets every pending event so
                # the caller wakes up and sees this state.
                raise OSError(f"jsonrpc connection closed mid-call to {method!r}")
        finally:
            with self._pending_lock:
                self._pending.pop(req_id, None)
        if "error" in resp and resp["error"] is not None:
            err = resp["error"]
            raise JsonRpcError(
                code=int(err.get("code", -1)),
                message=str(err.get("message", "")),
                data=err.get("data"),
            )
        return resp.get("result")

    def notify(self, method: str, params: object | None = None) -> None:
        """Fire-and-forget request (no `id`, no response expected)."""
        req: dict = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            req["params"] = params
        self._send_line(req)

    def _run_reader(self) -> None:
        try:
            while True:
                line = self._reader.readline()
                if not line:
                    return
                line = line.rstrip("\r\n")
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(msg, dict):
                    continue
                if "id" in msg and msg["id"] is not None and "method" not in msg:
                    self._deliver_response(int(msg["id"]), msg)
                elif "method" in msg and self._on_notification is not None:
                    try:
                        self._on_notification(str(msg["method"]), msg.get("params"))
                    except Exception:
                        # Notification handler crashes must not kill the
                        # read loop — the next response may be one the
                        # main thread is waiting on. Swallow silently;
                        # the handler is expected to log if it cares.
                        pass
        finally:
            self.close()
            if self._on_close is not None:
                try:
                    self._on_close()
                except Exception:
                    pass

    def _deliver_response(self, req_id: int, msg: dict) -> None:
        with self._pending_lock:
            evt = self._pending.get(req_id)
            if evt is None:
                return
            self._results[req_id] = msg
        evt.set()
