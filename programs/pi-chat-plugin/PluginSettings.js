.pragma library

// Helpers for mutating the persisted noctalia plugin settings.
//
// noctalia's plugin API exposes a mutable `pluginSettings` object,
// the manifest, and a `saveSettings()` method that persists the
// current settings and reassigns `pluginSettings` to a fresh copy so
// QML bindings re-evaluate. There is NO `setPluginSetting(key, value)`
// helper; callers mutate the dict directly and then call
// `saveSettings()`. Going through this helper keeps the panel from
// reaching for methods that don't exist on the real API.

function toggleBool(api, key) {
  if (!api) return;
  const fallback = api.manifest?.metadata?.defaultSettings?.[key] ?? false;
  const current = api.pluginSettings?.[key] ?? fallback;
  api.pluginSettings[key] = !current;
  api.saveSettings?.();
}
