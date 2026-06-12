Inline approval card for an agent's shell command (or any human gate). Pending shows Allow/Deny; once answered it stays as a colour-coded audit line. Since the executor owns the request, it can be answered from any device — pass `machine` to show who's asking and `answeredBy` for cross-device provenance.

```jsx
<ConfirmCard
  command="rm -rf ./node_modules && pnpm i"
  machine={{ name: "kiwi", color: "var(--m-primary)" }}
  onAllow={ok} onDeny={no} />

<ConfirmCard command="git push --force" state="allowed" answeredBy="answered on iPhone" />
```

- `state` — `pending` | `allowed` (mint border) | `denied` (pink border).
