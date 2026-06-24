# qmllint debt

`checks/pi-chat-qmllint` runs `qmllint --max-warnings 0` over every QML
file in this tree, so any warning is a build failure.

There is no per-file suppression left in this tree. Upstream
`Quickshell` qmltypes gaps that used to require `// qmllint disable …`
markers are now fixed by patching qmltypes in
`lib/qmllint-patch-qmltypes.py` (shared with the noctalia plugin checks
via `lib/qmllint.nix`). The patches affect only qmllint — the runtime
`pkgs.quickshell` plugin the panel loads is untouched. See the comment
block in that script for the rationale per patch (PanelWindow
isCreatable, FileView.adapter, Process/Socket enum params; the fourth,
the Margins value-type, is only reached by the noctalia checks).

If you hit a new qmllint warning and want to suppress it instead of
fixing the source, add a per-line `// qmllint disable <category>`
marker and document it here, including:

- file:line and category,
- why fixing it in source isn't the right move,
- if it's an upstream qmltypes bug: whether adding it to
  `lib/qmllint-patch-qmltypes.py` is feasible (preferred over per-line
  markers).

There is currently no source-level workaround in the tree beyond the
`readonly property alias _cfg: configAdapter` / `_sessions:
sessionsAdapter` lines in `PiChatBackend.qml`. Those are not really
debt — they exist because ids declared inside a `JsonAdapter` aren't
visible to bindings outside the enclosing `FileView`, which is a
scope-visibility quirk separate from any qmltypes gap.
