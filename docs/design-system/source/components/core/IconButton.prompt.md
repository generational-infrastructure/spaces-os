Square, icon-only control — the workhorse of the panel header and compose row. Rest state is a surface chip with a chartreuse glyph; hover flips the whole chip to mint with navy ink.

```jsx
<IconButton icon="search" title="Search" onClick={openSearch} />
<IconButton icon="microphone" title="Voice to text" active={recording} />
<IconButton icon="chevron-down" size={26} title="Next" />
```

- `size` defaults to 33px; corner radius is `min(16, size/2)` so small sizes render circular.
- `active` arms the control (error-red fill) — used for the recording toggle.
- Always pass `title` (used as tooltip + aria-label).
