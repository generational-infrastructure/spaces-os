"""Contract tests for the integration-signal MCP server.

Harness: an in-process fake signal-cli daemon speaking the minimal JSON-RPC
subset the server uses (listAccounts / listContacts / listGroups / send — the
method names + param/result shapes are the ones the real daemon uses, per
packages/signal-cli/spaces_signal/{bridge,jsonrpc}.py and the upstream
signal-cli-jsonrpc(5) man page) plus a fixture messages.db built with the
shared spaces_signal.db helpers. The server reaches the fake daemon with the
REAL spaces_signal.jsonrpc client, so the client/daemon wire shape is exercised.
"""

import json
import os
import socket
import sqlite3
import threading
import time
from types import SimpleNamespace

import pytest

import integration_signal
from spaces_signal import db as dbmod

# ── fake daemon fixtures ────────────────────────────────────────────

OWN_NUMBER = "+15550000000"
ACCOUNTS = [{"number": OWN_NUMBER, "uuid": "uuid-self"}]

CONTACTS = [
    {"number": "+15551230001", "uuid": "uuid-bob", "name": "Bob"},
    {
        "number": "+15551230002",
        "uuid": "uuid-alice",
        "name": "",
        "profile": {"givenName": "Alice", "familyName": ""},
    },
    # A RIGHT-TO-LEFT-OVERRIDE injected display name — sanitize_display must
    # strip it before the name check / preview.
    {"number": "+15551230004", "uuid": "uuid-rtl", "name": "Ma\u202em"},
]

GROUPS = [
    {
        "id": "TEAMGROUPID=",
        "name": "Team",
        "members": ["+15551230001", "+15551230002", "+15551230004"],
    },
]


class FakeDaemon:
    """Unix-socket JSON-RPC server; records every request it receives."""

    def __init__(self, sock_path, *, accounts, contacts, groups):
        self.sock_path = sock_path
        self.accounts = accounts
        self.contacts = contacts
        self.groups = groups
        self.requests = []
        self._stop = False
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass
        self._sock.bind(sock_path)
        self._sock.listen(8)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self):
        while not self._stop:
            try:
                conn, _ = self._sock.accept()
            except OSError:
                return
            threading.Thread(
                target=self._handle, args=(conn,), daemon=True
            ).start()

    def _handle(self, conn):
        with conn, conn.makefile("rb") as reader:
            for line in reader:
                line = line.strip()
                if not line:
                    continue
                req = json.loads(line)
                self.requests.append(req)
                resp = self._dispatch(req)
                conn.sendall(json.dumps(resp).encode("utf-8") + b"\n")

    def _dispatch(self, req):
        method = req.get("method")
        rid = req.get("id")
        if method == "listAccounts":
            result = self.accounts
        elif method == "listContacts":
            result = self.contacts
        elif method == "listGroups":
            result = self.groups
        elif method == "send":
            result = {"timestamp": 1234567890}
        else:
            return {
                "jsonrpc": "2.0",
                "id": rid,
                "error": {"code": -32601, "message": f"no method: {method}"},
            }
        return {"jsonrpc": "2.0", "id": rid, "result": result}

    def calls(self, method):
        return [r for r in self.requests if r.get("method") == method]

    def close(self):
        self._stop = True
        try:
            self._sock.close()
        except OSError:
            pass


def _build_db(path):
    db = dbmod.connect(path)
    fixtures = [
        {
            "uid": "m-bob-1",
            "ts_ms": 1_700_000_001_000,
            "thread_id": "uuid-bob",
            "thread_kind": "dm",
            "sender_uuid": "uuid-bob",
            "sender_name": "Bob",
            "body": "hello from bob",
            "attachments_json": [
                {
                    "id": "att-1",
                    "filename": "photo.jpg",
                    "contentType": "image/jpeg",
                    "size": 5,
                }
            ],
        },
        {
            "uid": "m-team-1",
            "ts_ms": 1_700_000_002_000,
            "thread_id": "TEAMGROUPID=",
            "thread_kind": "group",
            "sender_uuid": "uuid-carol",
            "sender_name": "Carol",
            "body": "standup at ten",
        },
        # A message whose stored attachment names attempt path traversal.
        {
            "uid": "m-evil-1",
            "ts_ms": 1_700_000_003_000,
            "thread_id": "uuid-bob",
            "thread_kind": "dm",
            "sender_uuid": "uuid-bob",
            "sender_name": "Bob",
            "body": "sketchy attachment",
            "attachments_json": [
                {
                    "id": "../../../../etc/passwd",
                    "filename": "../../evil.txt",
                    "contentType": "text/plain",
                    "size": 11,
                }
            ],
        },
    ]
    for msg in fixtures:
        dbmod.store_message(db, msg)
    db.close()


def _wait_sock(path, timeout=5.0):
    deadline = time.monotonic() + timeout
    while not os.path.exists(path):
        assert time.monotonic() < deadline, "daemon socket never appeared"
        time.sleep(0.01)


def _make_harness(tmp_path, monkeypatch, *, accounts=ACCOUNTS, with_socket=True):
    db_path = tmp_path / "messages.db"
    _build_db(db_path)

    att = tmp_path / "attachments"
    att.mkdir()
    (att / "att-1").write_bytes(b"PHOTO")
    # basename of the traversal id "../../../../etc/passwd"
    (att / "passwd").write_bytes(b"NEUTRALIZED")

    shared = tmp_path / "shared"
    shared.mkdir()

    sock = str(tmp_path / "daemon.sock")
    daemon = FakeDaemon(sock, accounts=accounts, contacts=CONTACTS, groups=GROUPS)
    _wait_sock(sock)

    monkeypatch.setenv("SPACES_SIGNAL_DB", str(db_path))
    monkeypatch.setenv("SPACES_SIGNAL_ATTACHMENTS_DIR", str(att))
    monkeypatch.setenv("SPACES_INTEGRATION_SHARED_DIR", str(shared))
    if with_socket:
        monkeypatch.setenv("SPACES_SIGNAL_DAEMON_SOCKET", sock)
    else:
        monkeypatch.setenv(
            "SPACES_SIGNAL_DAEMON_SOCKET", str(tmp_path / "missing.sock")
        )

    return SimpleNamespace(
        daemon=daemon,
        db_path=db_path,
        att=att,
        shared=shared,
        sock=sock,
        tmp=tmp_path,
    )


@pytest.fixture
def sig(tmp_path, monkeypatch):
    h = _make_harness(tmp_path, monkeypatch)
    yield h
    h.daemon.close()


def call(tool, **args):
    return integration_signal.call_tool(tool, args)


# ── protocol / schema ───────────────────────────────────────────────


def test_schema_json_matches_advertised_tools():
    here = os.path.dirname(os.path.abspath(integration_signal.__file__))
    with open(os.path.join(here, "schema.json")) as f:
        schema = json.load(f)
    assert schema["config"] == {}
    assert schema["secrets"] == {}
    assert schema["tools"] == [t["name"] for t in integration_signal.TOOLS]
    assert schema["tools"] == [
        "threads",
        "read_thread",
        "search",
        "contacts",
        "groups",
        "note_to_self",
        "send",
        "fetch_attachment",
        "send_preview",
    ]


def test_tools_list_has_no_profile_prop_and_no_fingerprint():
    names = [t["name"] for t in integration_signal.TOOLS]
    assert "secret_fingerprint" not in names
    assert "send_preview" in names
    for t in integration_signal.TOOLS:
        assert "profile" not in t["inputSchema"]["properties"]


# ── decision 11: daemon probe / onboarding hint ─────────────────────


def test_threads_unreachable_daemon_yields_onboarding_hint(tmp_path, monkeypatch):
    # Fixture DB HAS rows, but the daemon socket is absent: the probe must fire
    # first and surface the onboarding hint instead of masquerading as messages.
    h = _make_harness(tmp_path, monkeypatch, with_socket=False)
    h.daemon.close()  # ensure nothing is listening
    text, is_error = call("threads")
    assert is_error is True
    assert "signal-cli link -n" in text
    assert "hello from bob" not in text


def test_every_tool_probes_daemon(tmp_path, monkeypatch):
    h = _make_harness(tmp_path, monkeypatch, with_socket=False)
    h.daemon.close()
    for name, args in [
        ("threads", {}),
        ("read_thread", {"thread_id": "uuid-bob"}),
        ("search", {"query": "hello"}),
        ("contacts", {}),
        ("groups", {}),
        ("note_to_self", {"body": "x"}),
        ("send", {"recipient": "+15551230001", "name": "Bob", "body": "hi"}),
        ("fetch_attachment", {"message_uid": "m-bob-1", "index": 0}),
        ("send_preview", {"recipient": "+15551230001", "name": "Bob"}),
    ]:
        text, is_error = integration_signal.call_tool(name, args)
        assert is_error is True, name
        assert "signal-cli link -n" in text, name


def test_no_linked_account_is_treated_as_unlinked(tmp_path, monkeypatch):
    h = _make_harness(tmp_path, monkeypatch, accounts=[])
    try:
        text, is_error = call("threads")
        assert is_error is True
        assert "signal-cli link -n" in text
    finally:
        h.daemon.close()


# ── decision 1/8: read tools over the fixture DB ────────────────────


def test_threads_lists_from_db(sig):
    text, is_error = call("threads")
    assert is_error is False
    rows = json.loads(text)
    threads = {r["thread_id"] for r in rows}
    assert "uuid-bob" in threads
    assert "TEAMGROUPID=" in threads


def test_read_thread_surfaces_attachment_ids(sig):
    text, is_error = call("read_thread", thread_id="uuid-bob")
    assert is_error is False
    msgs = json.loads(text)
    bob = next(m for m in msgs if m["uid"] == "m-bob-1")
    assert bob["attachments"][0]["index"] == 0
    assert bob["attachments"][0]["filename"] == "photo.jpg"
    assert bob["attachments"][0]["id"] == "att-1"


def test_search_filters_body(sig):
    text, is_error = call("search", query="standup")
    assert is_error is False
    rows = json.loads(text)
    bodies = [r["body"] for r in rows]
    assert bodies == ["standup at ten"]


def test_contacts_lists_names_and_ids(sig):
    text, is_error = call("contacts")
    assert is_error is False
    rows = json.loads(text)
    by_number = {c.get("number"): c for c in rows}
    assert by_number["+15551230001"]["name"] == "Bob"
    # sanitize_display strips the RLO from the injected name.
    assert "\u202e" not in by_number["+15551230004"]["name"]


def test_groups_lists_titles_and_member_count(sig):
    text, is_error = call("groups")
    assert is_error is False
    rows = json.loads(text)
    team = next(g for g in rows if g["id"] == "TEAMGROUPID=")
    assert team["name"] == "Team"
    assert team["members"] == 3


# ── decision 2/3: send verification + strict recipients ─────────────


def test_send_verified_dispatches(sig):
    text, is_error = call(
        "send", recipient="+15551230001", name="Bob", body="hi bob"
    )
    assert is_error is False, text
    sends = sig.daemon.calls("send")
    assert len(sends) == 1
    assert sends[0]["params"]["recipient"] == ["+15551230001"]
    assert sends[0]["params"]["message"] == "hi bob"


def test_send_name_mismatch_refuses_with_true_name(sig):
    text, is_error = call(
        "send", recipient="+15551230001", name="Mallory", body="hi"
    )
    assert is_error is True
    assert "Bob" in text  # the true name is disclosed
    assert sig.daemon.calls("send") == []  # nothing dispatched


def test_send_name_mismatch_lists_near_misses(sig):
    # Claiming "Alicia" for Bob's number: refuses (name mismatch) AND the error
    # points at the near-miss "Alice" from the pooled namespace.
    text, is_error = call(
        "send", recipient="+15551230001", name="Alicia", body="hi"
    )
    assert is_error is True
    assert "Alice" in text
    assert sig.daemon.calls("send") == []


def test_send_name_required(sig):
    text, is_error = call("send", recipient="+15551230001", body="hi")
    assert is_error is True
    assert "name" in text.lower()
    assert sig.daemon.calls("send") == []


def test_send_unknown_number_refuses(sig):
    text, is_error = call(
        "send", recipient="+19998887777", name="Whoever", body="hi"
    )
    assert is_error is True
    assert "not in your contacts" in text
    assert "add them on your phone" in text
    assert sig.daemon.calls("send") == []


def test_send_unknown_username_refuses(sig):
    text, is_error = call("send", recipient="ghost.99", name="Ghost", body="hi")
    assert is_error is True
    assert "not in your contacts" in text
    assert sig.daemon.calls("send") == []


def test_send_to_own_number_routes_to_note_to_self(sig):
    text, is_error = call("send", recipient=OWN_NUMBER, name="Me", body="hi")
    assert is_error is True
    assert "note_to_self" in text
    assert sig.daemon.calls("send") == []


def test_send_literal_self_routes_to_note_to_self(sig):
    text, is_error = call("send", recipient="self", name="Me", body="hi")
    assert is_error is True
    assert "note_to_self" in text
    assert sig.daemon.calls("send") == []


# ── decision 4: groups ──────────────────────────────────────────────


def test_send_group_verified_dispatches(sig):
    text, is_error = call(
        "send", recipient="TEAMGROUPID=", name="Team", body="ping team"
    )
    assert is_error is False, text
    sends = sig.daemon.calls("send")
    assert len(sends) == 1
    assert sends[0]["params"]["groupId"] == "TEAMGROUPID="
    assert "recipient" not in sends[0]["params"]


def test_send_group_name_mismatch_refuses(sig):
    text, is_error = call(
        "send", recipient="TEAMGROUPID=", name="NotTeam", body="hi"
    )
    assert is_error is True
    assert "Team" in text
    assert sig.daemon.calls("send") == []


def test_send_unknown_group_refuses(sig):
    text, is_error = call(
        "send", recipient="UNKNOWNGROUPID=", name="Team", body="hi"
    )
    assert is_error is True
    assert "group" in text.lower()
    assert sig.daemon.calls("send") == []


# ── decision 10: note_to_self ───────────────────────────────────────


def test_note_to_self_sends_to_own_number_no_name(sig):
    text, is_error = call("note_to_self", body="remember milk")
    assert is_error is False, text
    sends = sig.daemon.calls("send")
    assert len(sends) == 1
    assert sends[0]["params"]["recipient"] == [OWN_NUMBER]
    assert sends[0]["params"]["message"] == "remember milk"


# ── decision 6: send_preview + similarity ───────────────────────────


def test_preview_contact_to_line(sig):
    text, is_error = call("send_preview", recipient="+15551230001", name="Bob")
    assert is_error is False
    assert "to: Bob <+15551230001>" in text


def test_preview_group_to_line_with_member_count(sig):
    text, is_error = call("send_preview", recipient="TEAMGROUPID=", name="Team")
    assert is_error is False
    assert 'to: GROUP "Team" (3 members)' in text


def test_preview_issues_no_send_rpc(sig):
    # Preview purity: computing a preview must never dispatch a message.
    call("send_preview", recipient="+15551230001", name="Bob")
    assert sig.daemon.calls("send") == []


def test_preview_warns_on_levenshtein_near_miss():
    warnings = integration_signal._similarity_scan(
        "Alice", [("Alicia", "+15551230009"), ("Bob", "+15551230001")]
    )
    joined = "\n".join(warnings)
    assert "similar" in joined
    assert "Alicia" in joined
    assert "+15551230009" in joined  # raw id beside the candidate


def test_preview_flags_cyrillic_confusable():
    # "\u0410lice" = Cyrillic capital A + "lice"
    warnings = integration_signal._similarity_scan(
        "Alice", [("\u0410lice", "+15551230003")]
    )
    joined = "\n".join(warnings)
    assert "confusable" in joined
    assert "mixed-script" in joined
    assert "+15551230003" in joined


def test_preview_flags_greek_confusable():
    # "\u0391\u03bf\u03ba\u03b9" = Greek Alpha/omicron/kappa/iota, looks like "Aoki"
    warnings = integration_signal._similarity_scan(
        "Aoki", [("\u0391\u03bf\u03ba\u03b9", "+15551230010")]
    )
    joined = "\n".join(warnings)
    assert "confusable" in joined
    assert "mixed-script" in joined


def test_similarity_ignores_exact_match():
    warnings = integration_signal._similarity_scan(
        "Bob", [("Bob", "+15551230001")]
    )
    assert warnings == []


# ── decision 7: fetch_attachment ────────────────────────────────────


def test_fetch_attachment_copies_into_shared_dir(sig):
    text, is_error = call("fetch_attachment", message_uid="m-bob-1", index=0)
    assert is_error is False, text
    path = text.strip()
    assert os.path.dirname(path) == str(sig.shared)
    assert os.path.basename(path) == "photo.jpg"
    with open(path, "rb") as f:
        assert f.read() == b"PHOTO"


def test_fetch_attachment_neutralizes_path_traversal(sig):
    text, is_error = call("fetch_attachment", message_uid="m-evil-1", index=0)
    assert is_error is False, text
    path = text.strip()
    # destination stays inside the shared dir, basename only
    assert os.path.dirname(path) == str(sig.shared)
    assert os.path.basename(path) == "evil.txt"
    # source was read by basename ("passwd") from inside the attachments dir,
    # never escaping to a real /etc/passwd.
    with open(path, "rb") as f:
        assert f.read() == b"NEUTRALIZED"


# ── decision 8: read-only DB connection ─────────────────────────────


def test_db_connection_is_read_only(sig):
    db = integration_signal._open_db(sig.db_path)
    try:
        with pytest.raises(sqlite3.OperationalError):
            db.execute(
                "INSERT INTO messages (uid, ts_ms, received_at_ms, thread_id,"
                " thread_kind) VALUES ('forged', 0, 0, 't', 'dm')"
            )
    finally:
        db.close()
