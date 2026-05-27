# Icons

Outline-style SVGs from [Tabler Icons](https://tabler.io/icons), MIT
licensed (see `LICENSE`). Vendored verbatim — fetch refreshes via:

```bash
for name in $(ls *.svg | sed 's/\.svg$//'); do
  curl -sfL -o "$name.svg" \
    "https://raw.githubusercontent.com/tabler/tabler-icons/main/icons/outline/$name.svg"
done
```

`Widgets/NIcon.qml` loads them by name from this directory at runtime.
Add new icons by dropping the SVG here.
