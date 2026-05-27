// Translation singleton.
//
// Replacement for noctalia's `pluginApi.tr(key, args)`. Locale is
// resolved once at startup from $LANG; the matching JSON under
// `<shellDir>/i18n/<locale>.json` is loaded on first `tr()` call
// (FileView.blockLoading guarantees text() returns the file content
// even if disk I/O hasn't completed yet) and cached for the lifetime
// of the singleton. en.json is the canonical fallback for missing
// keys and missing locales alike.
//
// Strings use `{placeholder}` syntax; args is an optional
// `{placeholder: value}` map. Unknown placeholders render as the
// literal `{name}` so debugging is obvious; unknown keys render as
// the key itself.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
  id: root

  // Best-effort locale extraction: $LANG looks like "en_US.UTF-8" or
  // "de_DE@euro"; the leading "<lang>_<region>" portion is what
  // matters. Missing env → "en". Hyphens are normalised to
  // underscores so the filename matches what we ship (zh_CN.json).
  readonly property string locale: {
    const raw = Quickshell.env("LANG") || Quickshell.env("LC_ALL") || "en";
    const m = String(raw).match(/^([a-z]{2,3}(?:[-_][A-Z]{2,3})?)/i);
    if (!m) return "en";
    return m[1].replace(/-/g, "_");
  }

  // Cached flattened maps, populated on first `tr()`. Empty objects
  // until then so the first lookup falls through to the file load.
  property var _strings: null
  property var _fallbackStrings: null

  function tr(key, args) {
    if (_strings === null) _loadLocale();
    if (_fallbackStrings === null) _loadFallback();
    let s = _strings[key];
    if (s === undefined) s = _fallbackStrings[key];
    if (s === undefined) return key;
    if (!args) return s;
    return String(s).replace(/\{([^}]+)\}/g, function (_, k) {
      return args.hasOwnProperty(k) ? String(args[k]) : "{" + k + "}";
    });
  }

  // Flatten nested JSON ({"panel":{"foo":"bar"}}) into dotted keys
  // ({"panel.foo":"bar"}) so callers can `tr("panel.foo")` directly.
  function _flatten(obj, prefix, out) {
    for (const k in obj) {
      const v = obj[k];
      const fk = prefix ? prefix + "." + k : k;
      if (v !== null && typeof v === "object" && !Array.isArray(v)) {
        _flatten(v, fk, out);
      } else {
        out[fk] = v;
      }
    }
  }

  function _loadJsonInto(view, prop, label) {
    // `text()` blocks until the FileView's `blockLoading: true`
    // background read completes. Missing file → empty string; we
    // treat that as an empty cache (the fallback layer handles
    // lookups) without logging a parse error.
    const t = (view.text() || "").trim();
    if (t === "") { root[prop] = {}; return; }
    try {
      const out = {};
      _flatten(JSON.parse(t), "", out);
      root[prop] = out;
    } catch (e) {
      Logger.w("I18n", "parse failed for", label, e);
      root[prop] = {};
    }
  }

  function _loadLocale() { _loadJsonInto(_localeFile, "_strings", root.locale); }
  function _loadFallback() { _loadJsonInto(_fallbackFile, "_fallbackStrings", "en"); }

  property FileView _localeFile: FileView {
    path: Quickshell.shellDir + "/i18n/" + root.locale + ".json"
    blockLoading: true
    printErrors: false
  }

  property FileView _fallbackFile: FileView {
    path: Quickshell.shellDir + "/i18n/en.json"
    blockLoading: true
    printErrors: false
  }

  // Force both files to load before any binding can call tr().
  // Qt diagnoses a binding loop when tr() mutates I18n._strings /
  // I18n._fallbackStrings inside the same evaluation cycle that
  // depends on them. Eager-loading converts those mutations into
  // pre-binding initialisation, so every binding sees populated
  // caches on its first evaluation.
  Component.onCompleted: {
    _loadLocale();
    _loadFallback();
  }
}
