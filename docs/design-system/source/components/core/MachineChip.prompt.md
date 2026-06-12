Identity chip for a machine (executor). Colour tells you *which* machine; the StatusDot tells you whether you can reach it. Reuse one colour per machine across tabs, headers, and list rows so it's instantly recognisable.

```jsx
<MachineChip name="kiwi"   color="var(--m-primary)"   status="online" />
<MachineChip name="studio" color="var(--m-secondary)" status="offline" />
<MachineChip name="nas"    color="var(--m-tertiary)"  status="working" relayed />
<MachineChip name="kiwi"   color="var(--m-primary)"   variant="solid" />  {/* active selection */}
```

- `color` — the machine's stable accent (palette roles: `--m-primary`, `--m-secondary`, `--m-tertiary`, …). Keep it constant per machine.
- `status` — optional; renders a leading StatusDot (`online`/`offline`/`working`/`idle`).
- `variant` — `outline` (default), `ghost` (bare), `solid` (filled, for the selected machine). `size` — `sm` | `md`.
