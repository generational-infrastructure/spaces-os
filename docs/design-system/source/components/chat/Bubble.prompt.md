A single chat row. Author is signalled by alignment + fill, not an avatar: own messages sit right on chartreuse, peer/assistant left on surface-variant with a hairline.

```jsx
<Bubble from="peer" text="On it — scanning the deploy script now." time="now" tps={48.2} />
<Bubble from="me" text="ship it" time="2m" ack="read" />
<Bubble from="peer" text="Reasoning…" variant="thinking" />
<Bubble variant="notification" text="kiwi · context cleared" />
<Bubble from="peer" text="…" streaming quote="ship it" />
```

- `from` — `me` | `peer`. `ack` (own only): `pending`/`sent`/`read`/`warn`. `tps` (peer only) shows a tokens/sec footer.
- `variant` — `text` | `notification` | `thinking`. `quote` renders a tappable reply snippet. `searchHit`/`searchCurrent` add the search outline.
