# NixOS role profiles (`spaces.profile`)

`nixosModules.default` is the SpacesOS bundle with a single required knob that
picks a machine's role:

```nix
{
  imports = [ spaces.nixosModules.default ];
  spaces.profile = "server";   # or "desktop" / "minimal"
}
```

`spaces.profile` has **no default** — a machine must state its role, or eval
fails loudly (better than silently getting the wrong one).

## The three roles (cumulative)

`minimal ⊂ server ⊂ desktop` — each is a strict superset of the one before.

| role | what you get |
|---|---|
| `minimal` | just the nix daemon settings (flakes, experimental features). The escape hatch for a host that wants the flake plumbing and none of the opinions. |
| `server` | minimal **+** a hardened, headless baseline: no docs/fonts/xreadmes, sshd + hardening, `userborn`, sensible systemd/boot/nix defaults, sysctl network hygiene, `wait-online` off, nix-daemon build de-prioritisation, UTC. No GUI. |
| `desktop` | server **+** the full GUI/agent stack: `pi-chat`, niri, noctalia, greetd autologin. |

## `default` vs `spaces` vs the leaf modules

- **`nixosModules.default`** — the role switch above. Preferred for new configs.
- **`nixosModules.spaces`** — back-compat alias that pins `profile = "desktop"`.
  Existing importers keep getting the full desktop unchanged.
- **`nixosModules.pi-chat`** (and the other leaf modules) — import a single piece
  onto a desktop you already run, no profile needed.

Because NixOS `imports` can't depend on an option value, every sub-module is
imported unconditionally and gated by its own (default-off) `enable`, which the
profile drives. A `server`/`minimal` host therefore pulls in **zero**
wayland/niri/greetd config.

## The server baseline & upstream-default tracking

The `server` role flips a number of NixOS defaults toward a hardened headless
posture. Plain, introspectable options live in a `serverDefaults` attrset
(`modules/nixos/default.nix`), applied as `lib.mkDefault` so a host can still
override any of them.

Each flip is checked **mechanically** against upstream: the module reads
`options.<path>.default` (upstream's own declared default, unaffected by our
`mkDefault`) and **emits a `warning` when upstream's default already equals
ours** — i.e. the flip has become redundant and should be deleted. So a nixpkgs
bump tells you which entries to drop instead of anyone hand-diffing.

Freeform settings (`nix.settings.*`, `boot.kernel.sysctl.*`, sshd
`services.openssh.settings.*`) have no `options.<path>.default` to compare, so
they stay inline with a terse note rather than in `serverDefaults`. Likewise a
couple of deliberate safety-nets (e.g. `firewall.enable`) are kept explicit even
though upstream matches them.

### Adding a server default

- **Introspectable option** (has `options.<path>.default`): add
  `"the.option.path" = value;` to `serverDefaults`. Redundancy is then
  auto-detected on every bump.
- **Freeform setting** (`nix.settings`, sysctl, sshd settings): set it inline in
  the server block with a one-line note; these can't be auto-checked.

## Not included

The aggressive `profiles/hardened.nix`-class knobs (`lockKernelModules`,
`protectKernelImage`, `forcePageTableIsolation`, `io_uring` off, kernel
`kernelParams`, `nix.settings.allowed-users`) are intentionally left out of the
baseline — they break kexec / runtime module loading / build users per host.
They belong behind a future opt-in, not a silent `mkDefault`.
