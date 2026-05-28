# qmllint debt

`checks/pi-chat-qmllint` runs `qmllint --max-warnings 0` over every QML
file in this tree, so any warning is a build failure. A handful of
warnings can't be fixed from this side; we suppress them per-line with
`// qmllint disable <category>` markers and explain each one below.

If you add a new `qmllint disable`, you **MUST** add a matching entry
here. CI does not enforce this — the reviewer does.

## Suppressions

### `uncreatable-type` — `PanelWindow`
- `shell.qml:23`

`Quickshell.PanelWindow` is created via the Wayland layer-shell at
runtime, but its qmltypes proxy is registered as not-creatable so
qmllint refuses to instantiate it. There is no user-side workaround;
needs a quickshell upstream fix.

### `unresolved-type` — `JsonAdapter.adapter` proxy
- `Commons/Settings.qml:49`
- `PiChatBackend.qml:45` (config JSON)
- `PiChatBackend.qml:138` (sessions JSON)

`Quickshell.Io.FileView.adapter` is typed as `FileViewAdapter` in the
qmltypes, which qmllint treats as incomplete. The runtime relationship
is fine — `FileView` accepts a `JsonAdapter` child unchanged. Same
upstream-fix story.

A side-effect of the proxy type being opaque: ids declared inside the
adapter (e.g. `id: configAdapter`) aren't visible to bindings outside
the FileView, so qmllint flags every outer access as `unqualified`.
The workaround is the `readonly property alias _cfg: configAdapter` /
`_sessions: sessionsAdapter` aliases in PiChatBackend.qml.

### `signal-handler-parameters` — `QProcess::ExitStatus`, `QLocalSocketError`
- `OpenUrlListener.qml:37`   (Process.onExited)
- `Panel.qml:732`           (paste image Process.onExited)
- `PiChatBackend.qml:378`   (skill subscriber Socket.onError)
- `PiChatBackend.qml:402`   (skill one-shot Socket.onError)
- `PiChatBackend.qml:639`   (one-shot Process.onExited)
- `PiSession.qml:835`       (main pi Process.onExited)
- `PiSession.qml:857`       (stop Process.onExited)
- `PiSession.qml:866`       (memory-marker Process.onExited)
- `PiSession.qml:874`       (image reader Process.onExited)
- `SignalConfirm.qml:111`   (bridge Socket.onError)

`Process.exited(int, QProcess::ExitStatus)` and `Socket.error(
QLocalSocket::LocalSocketError)` reference Qt-side enum types whose
qmltypes registration is missing from `Quickshell.Io` — qmllint
demands the second parameter be a resolvable type even when the
handler doesn't use it. Typed handler annotations (`code: int`, etc.)
do not help; qmllint validates the *signal*'s declared type, not the
slot signature.

### `missing-property` on dynamic QObject refs
- `PiChatBackend.qml:359` (`Loader.item?.connected`)
- `PiChatBackend.qml:567`,`568` (`obj.needsPersist`, `obj.incomingNotification`)

`Loader.item` is typed as `QObject`; the qmltypes don't narrow it to
the actual component. Same for PiSession instances that we hold via a
`var` map (`_sessionObjs[id]`) — qmllint loses the type. Replacing the
`var` map with a typed container (an `ObjectModel` or
`Repeater.itemAt(i)`) is the right long-term fix.

### `Quick.anchor-combinations` — conditional anchor selection
- `Bubble.qml:81`

The bubble's `anchors.left`/`anchors.right`/`anchors.horizontalCenter`
bindings each evaluate to `undefined` when not in use, so at runtime
only one anchor is set. qmllint flags the three-way pattern statically
because it doesn't model `undefined`-clears-anchor semantics. A cleaner
fix is splitting into a State machine, but the current binding pattern
is clearer; suppression keeps it that way.
