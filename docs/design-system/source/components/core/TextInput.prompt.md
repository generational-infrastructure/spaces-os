Text field; the outline turns the accent colour on focus. Single-line by default, `multiline` for the compose box.

```jsx
<TextInput placeholder="Search messages…" value={q} onChange={e => setQ(e.target.value)} />
<TextInput multiline tone="compose" rows={1} placeholder="Message kiwi…" />
```

- `tone="compose"` uses the surface fill + periwinkle focus ring (the panel's compose box); default uses the surface-variant fill + chartreuse ring.
