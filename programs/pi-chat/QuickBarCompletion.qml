// Launch-bar completion — overlay candidate list + the `completer`
// controller it shares with QuickBar.qml.
//
// QuickBar owns the text field; this owns the *meaning* of what's typed.
// It mirrors the field's text+cursor (the controller is the single source
// of truth so accept()/advance() can rewrite it), tokenizes through the
// pure BarParse helper on every change, and exposes the keyboard contract
// the bar's Keys.onPressed drives (advance/move/accept/enter/escape). The
// candidate surface is a sibling Rectangle that grows the bar upward — no
// second layer-shell, no Popup that would clip above the input.
//
// See docs/superpowers/specs/2026-06-01-launch-bar-completion-plan.md §4.
pragma ComponentBehavior: Bound
import QtQuick
import qs.Commons
import qs.Widgets
import "BarParse.js" as BarParse

Item {
  id: root

  property var backend: null

  // The field's contents, owned here so a completion can rewrite them.
  // QuickBar binds its NTextInput to these and pushes user edits back via
  // setInput(); the controller never reaches into the field directly.
  property string text: ""
  property int cursor: 0

  // mode is a plain int + JS consts rather than a QML `enum` block: enums
  // are only allowed in singletons under strict qmllint, and this is a
  // per-bar component.
  readonly property int modeNone: 0
  readonly property int modeKey: 1
  readonly property int modeValue: 2

  property int mode: root.modeNone
  property bool active: false
  // [{ value, label }] — `label` is what the row shows, `value` is what a
  // value-completion inserts. For directive keys value==key, label=="/key:".
  property var candidates: []
  property int selectedIndex: -1
  property string partial: ""
  // Set when active but no rows to offer: a loading probe or a dead end
  // (no matching model / unknown directive). Rendered in place of the list.
  property bool loading: false
  property string note: ""

  // The single registered directive today. Kept in code (not i18n): the
  // "/model:" token is grammar, not a translatable label.
  readonly property var directiveKeys: [{ key: "model", label: "/model:" }]

  // The Enter dispatcher's last decision, for QuickBar (hide on launch)
  // and for the headless check to assert against without a live worker.
  property string lastStatus: ""
  property string lastLaunchPrompt: ""
  property string lastLaunchModel: ""

  signal applied()

  // Re-tokenize whenever the field OR the model cache changes — the value
  // list must repopulate when refreshModels() resolves after the list was
  // first opened on an empty cache.
  readonly property var modelsSnapshot: root.backend ? root.backend.modelsList : []
  readonly property bool modelsAreLoaded: root.backend ? root.backend.modelsLoaded : false
  onModelsSnapshotChanged: root._refresh()
  onModelsAreLoadedChanged: root._refresh()

  // A dismissed list (Esc) must stay closed until the token actually
  // changes, so a stray re-tokenize doesn't immediately reopen it.
  property string _dismissedKey: ""

  function setInput(t, c) {
    root.text = String(t === undefined || t === null ? "" : t);
    root.cursor = Math.max(0, Math.min(root.text.length, parseInt(c, 10) || 0));
    root._refresh();
  }

  function _models() {
    const arr = root.backend ? root.backend.modelsList : [];
    return Array.isArray(arr) ? arr : [];
  }

  function _keyCandidates(prefix) {
    const out = [];
    for (const d of root.directiveKeys) {
      if (d.key.indexOf(prefix) === 0) out.push({ value: d.key, label: d.label });
    }
    return out;
  }

  function _valueCandidates(prefix) {
    const out = [];
    for (const m of root._models()) {
      if (m && m.id && String(m.id).indexOf(prefix) === 0)
        out.push({ value: m.id, label: m.id });
    }
    return out;
  }

  // Longest common prefix of the candidate `value`s — what an ambiguous
  // Tab inserts so the list can stay open on the narrowed set.
  function _lcp(list) {
    if (!list.length) return "";
    let p = String(list[0].value);
    for (let i = 1; i < list.length; i++) {
      const v = String(list[i].value);
      let n = 0;
      while (n < p.length && n < v.length && p[n] === v[n]) n++;
      p = p.slice(0, n);
      if (p === "") break;
    }
    return p;
  }

  function _refresh() {
    const r = BarParse.parse(root.text, root.cursor);
    const tok = r.cursorToken;
    const key = tok ? tok.kind : "prompt";

    // Only an actual "/" (typed, or Tab-revealed via advance()) opens the
    // directive menu. A freshly-summoned empty bar stays calm: the
    // placeholder's "/ for options" hint invites the trigger, rather than a
    // loud pre-selected menu firing the instant the bar appears (and an
    // accidental Enter then injecting "/model:" into an otherwise empty bar).
    if (key === "slash") {
      root._openKey("");
    } else if (key === "key") {
      root._openKey(tok.partial);
    } else if (key === "value") {
      root._openValue(tok.key, tok.partial);
    } else {
      root._close();
    }

    // Honour a prior Esc until the token moves on.
    if (root.active && root._tokenKey() === root._dismissedKey) {
      root.active = false;
    } else {
      root._dismissedKey = "";
    }
  }

  // Identity of the current token+caret, for the Esc-stays-closed guard.
  function _tokenKey() {
    return root.text + " " + root.cursor;
  }

  function _openKey(prefix) {
    root.mode = root.modeKey;
    root.partial = prefix;
    root.candidates = root._keyCandidates(prefix);
    root.loading = false;
    root.note = root.candidates.length ? "" : I18n.tr("quickbar.unknown-directive");
    root.active = true;
    root.selectedIndex = root.candidates.length ? 0 : -1;
  }

  function _openValue(key, prefix) {
    root.mode = root.modeValue;
    root.partial = prefix;
    if (key !== "model") {
      root.candidates = [];
      root.loading = false;
      root.note = I18n.tr("quickbar.unknown-directive");
      root.active = true;
      root.selectedIndex = -1;
      return;
    }
    root.candidates = root._valueCandidates(prefix);
    if (root.candidates.length) {
      root.loading = false;
      root.note = "";
      root.active = true;
      root.selectedIndex = 0;
      return;
    }
    // No rows: either the cache hasn't loaded yet (loading) or it has and
    // nothing matches (dead end). Both keep the surface open with a note.
    root.loading = !root.modelsAreLoaded && root._models().length === 0;
    root.note = root.loading ? I18n.tr("quickbar.loading-models") : I18n.tr("quickbar.no-matches");
    root.active = true;
    root.selectedIndex = -1;
  }

  function _close() {
    root.active = false;
    root.mode = root.modeNone;
    root.candidates = [];
    root.selectedIndex = -1;
    root.partial = "";
    root.loading = false;
    root.note = "";
  }

  // The whitespace-delimited token under the caret. Neither a directive
  // key nor a model id contains whitespace, so this cleanly spans
  // "/model:partial" without re-implementing the grammar split.
  function _tokenBounds() {
    const t = root.text;
    let s = Math.min(root.cursor, t.length);
    while (s > 0 && !root._isSpace(t[s - 1])) s--;
    let e = Math.min(root.cursor, t.length);
    while (e < t.length && !root._isSpace(t[e])) e++;
    return { start: s, end: e };
  }

  function _isSpace(c) {
    return c === " " || c === "\t" || c === "\n" || c === "\r";
  }

  function _replaceToken(newToken, caretOffsetIntoToken) {
    const b = root._tokenBounds();
    const prefix = root.text.slice(0, b.start);
    const suffix = root.text.slice(b.end);
    root.text = prefix + newToken + suffix;
    root.cursor = prefix.length + caretOffsetIntoToken;
    root._dismissedKey = "";
    root._refresh();
    root.applied();
  }

  // Tab. Never silently picks among ambiguous candidates: a bare trigger
  // reveals, a unique prefix completes, an ambiguous one inserts the LCP
  // and keeps the list open (plan §4.2).
  function advance() {
    if (!root.active) {
      // Tab on a calm, closed bar reveals the directive menu — the §4.7
      // "Tab on an empty bar can also open it" affordance, preserved now
      // that summon no longer auto-opens. A non-empty closed bar (a finished
      // prompt) has nothing to complete, so Tab there stays a no-op.
      if (root.text.trim() === "")
        root._openKey("");
      return;
    }

    const prefix = root.partial;
    if (root.mode === root.modeKey) {
      if (prefix === "") return; // bare "/" or empty bar: reveal only
      const matches = root._keyCandidates(prefix);
      if (matches.length === 0) return;
      if (matches.length === 1) {
        root._replaceToken("/" + matches[0].value + ":", matches[0].value.length + 2);
      } else {
        const lcp = _lcp(matches);
        if (lcp.length > prefix.length) root._replaceToken("/" + lcp, lcp.length + 1);
      }
      return;
    }
    if (root.mode === root.modeValue) {
      if (root.candidates.length === 0) return; // unknown key / loading
      if (prefix === "") return; // "/model:" — reveal the list, don't pick
      const matches = root._valueCandidates(prefix);
      if (matches.length === 1) {
        root._acceptValue(matches[0].value);
      } else if (matches.length > 1) {
        const lcp = _lcp(matches);
        if (lcp.length > prefix.length) root._acceptValue(lcp);
      }
    }
  }

  // Up/Down (and Shift+Tab as -1). Wraps. Only meaningful with rows. Does
  // NOT re-tokenize — that would reset the selection back to the first row.
  function move(d) {
    const n = root.candidates.length;
    if (!root.active || n === 0) return;
    const base = root.selectedIndex < 0 ? 0 : root.selectedIndex;
    root.selectedIndex = ((base + d) % n + n) % n;
  }

  // Accept the highlighted row. Key → open the value list; value → insert
  // the model id (caret left at its end so the user types a space to move
  // into the prompt, per the §4.2 example which keeps the text exactly
  // "/model:<id>").
  function accept() {
    if (!root.active || root.selectedIndex < 0 || root.selectedIndex >= root.candidates.length)
      return;
    const chosen = root.candidates[root.selectedIndex];
    if (root.mode === root.modeKey) {
      root._replaceToken("/" + chosen.value + ":", chosen.value.length + 2);
    } else if (root.mode === root.modeValue) {
      root._acceptValue(chosen.value);
    }
  }

  function _acceptValue(value) {
    const b = root._tokenBounds();
    const tokenText = root.text.slice(b.start, b.end);
    const colon = tokenText.indexOf(":");
    const key = colon >= 0 ? tokenText.slice(1, colon) : "model";
    const newToken = "/" + key + ":" + value;
    // _replaceToken re-tokenizes, so an ambiguous LCP insert reopens the
    // value list on the now-narrower prefix with no extra bookkeeping.
    root._replaceToken(newToken, newToken.length);
  }

  function _isKnownKey(k) {
    for (const d of root.directiveKeys) if (d.key === k) return true;
    return false;
  }

  function _resolveModel(id) {
    for (const m of root._models()) {
      if (m && m.id === id) return (m.provider || "") + "/" + m.id;
    }
    return "";
  }

  // Enter. When the list is open this accepts; otherwise it launches the
  // parsed prompt (directives stripped), but only if the input is real:
  // an empty stripped prompt, an invalid model value, or an unknown
  // directive key all stay open without firing (plan §4a).
  function enter() {
    if (root.active) {
      root.accept();
      root.lastStatus = "accept";
      return root.lastStatus;
    }
    const r = BarParse.parse(root.text, root.cursor);
    for (const k in r.directives) {
      if (!root._isKnownKey(k)) {
        root._failOpen(I18n.tr("quickbar.unknown-directive"));
        root.lastStatus = "unknown";
        return root.lastStatus;
      }
    }
    let model = "";
    if (r.directives.hasOwnProperty("model")) {
      model = root._resolveModel(r.directives.model);
      if (model === "") {
        root._failOpen(I18n.tr("quickbar.no-matches"));
        root.lastStatus = "invalid";
        return root.lastStatus;
      }
    }
    const prompt = String(r.prompt || "").trim();
    if (prompt === "") {
      root.lastStatus = "noop";
      return root.lastStatus;
    }
    const opts = {};
    if (model !== "") opts.model = model;
    root.lastLaunchPrompt = prompt;
    root.lastLaunchModel = model;
    if (root.backend) root.backend.launchBackground(prompt, opts);
    root.lastStatus = "launch";
    return root.lastStatus;
  }

  // Surface the dead-end inline rather than launching: keep the bar open
  // with a note so the bad token is obviously the problem.
  function _failOpen(message) {
    root.mode = root.modeValue;
    root.candidates = [];
    root.selectedIndex = -1;
    root.loading = false;
    root.note = message;
    root.active = true;
  }

  // Esc. Closes the list first; a second Esc (list already closed) returns
  // "hide" so QuickBar drops the bar. (Named dismiss(), not escape(): the
  // QML engine reserves `escape` as a method name.)
  function dismiss() {
    if (root.active) {
      root.active = false;
      root._dismissedKey = root._tokenKey();
      root.lastStatus = "close";
    } else {
      root.lastStatus = "hide";
    }
    return root.lastStatus;
  }

  // ── overlay ──
  // A row is ~80% of a widget; cap the visible window and let the rest
  // scroll so a long model list can't sprawl the bar over the screen.
  readonly property int rowHeight: Math.round(Style.baseWidgetSize * 0.82)
  readonly property int maxVisibleRows: 6
  readonly property int _rowCount: root.candidates.length > 0 ? root.candidates.length : 1
  readonly property int _visibleRows: Math.min(root._rowCount, root.maxVisibleRows)

  implicitHeight: root.active ? root._visibleRows * root.rowHeight + Style.marginS * 2 : 0
  // Smooth the upward grow/shrink so the bar never jumps a row's worth of
  // height in one frame; the surface opacity fade below runs in lockstep.
  Behavior on implicitHeight {
    NumberAnimation { duration: Style.animationFast; easing.type: Easing.OutCubic }
  }

  Rectangle {
    id: surface
    anchors.fill: parent
    radius: Style.radiusS
    color: Color.mSurface
    border.color: Color.mOutline
    border.width: Style.borderS
    // Stay painted through the close animation — `active` flips false before
    // the height finishes shrinking, so gate on height to keep the fade
    // visible rather than snapping the list away.
    visible: root.implicitHeight > 0.5
    opacity: root.active ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Style.animationFast } }

    NListView {
      id: list
      anchors.fill: parent
      anchors.margins: Style.marginS
      clip: true
      visible: root.candidates.length > 0
      model: root.candidates
      currentIndex: root.selectedIndex
      boundsBehavior: Flickable.StopAtBounds

      delegate: Rectangle {
        id: row
        required property var modelData
        required property int index
        width: ListView.view ? ListView.view.width : 0
        height: root.rowHeight
        radius: Style.radiusXS
        color: root.selectedIndex === row.index ? Color.mPrimary : "transparent"

        NText {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.marginS
          anchors.rightMargin: Style.marginS
          anchors.verticalCenter: parent.verticalCenter
          text: row.modelData && row.modelData.label ? String(row.modelData.label) : ""
          pointSize: Style.fontSizeS
          color: root.selectedIndex === row.index ? Color.mOnPrimary : Color.mOnSurface
        }

        MouseArea {
          anchors.fill: parent
          onClicked: {
            root.selectedIndex = row.index;
            root.accept();
          }
        }
      }
    }

    NText {
      anchors.centerIn: parent
      visible: root.candidates.length === 0
      text: root.note
      pointSize: Style.fontSizeS
      color: Color.mOnSurfaceVariant
    }
  }

  // Keep the highlighted row on-screen as selection wraps through a list
  // taller than the visible window.
  onSelectedIndexChanged: {
    if (root.selectedIndex >= 0) list.positionViewAtIndex(root.selectedIndex, ListView.Contain);
  }
}
