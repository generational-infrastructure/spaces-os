Inline Tabler-outline icon (24px grid, 2px stroke, `currentColor`) — the exact set vendored in the pi-chat panel; use it anywhere the brand needs a glyph.

```jsx
<Icon name="send" size={20} />
<Icon name="brain" size={18} style={{ color: "var(--accent)" }} />
```

- `name` — one of the 26 vendored names (`send`, `search`, `brain`, `sparkles`, `paperclip`, `microphone`, `rotate`, `eraser`, `dots-vertical`, `message-chatbot`, …).
- Inherits `color` from context — set the parent's `color` (or pass `style={{ color }}`) to recolour.
- `size` defaults to 20; pass `title` for an accessible label, otherwise it is `aria-hidden`.
