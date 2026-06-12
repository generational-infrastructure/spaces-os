Pill-shaped labeled button with a hairline outline; the brand's primary call to action (filled chartreuse) plus neutral and danger variants.

```jsx
<Button onClick={send}>Send</Button>
<Button variant="neutral">Cancel</Button>
<Button variant="danger" icon="eraser">Wipe</Button>
```

- `variant` — `primary` (filled `--m-primary`, navy ink), `neutral` (raised surface), `danger` (error fill). Default `primary`.
- `icon` — optional leading Tabler icon name.
- Hover brightens the fill; `disabled` drops opacity to 0.6.
