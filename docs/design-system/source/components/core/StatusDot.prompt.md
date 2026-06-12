Tiny colour-coded state dot — reachability, agent activity, unread marks.

```jsx
<StatusDot status="online" />
<StatusDot status="working" size={10} />
```

- `status` — `online` (mint), `offline`/`error` (pink), `working` (chartreuse, pulses), `idle` (muted).
- `size` defaults to 8px.
