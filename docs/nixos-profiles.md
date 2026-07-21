# NixOS role profiles (`spaces.profile`)

`nixosModules.default` is the lean SpacesOS base with a single required knob
that picks a machine's role:

```nix
{
  imports = [ spaces.nixosModules.default ];
  spaces.profile = "server";   # or "minimal"
}
```

`spaces.profile` has **no default** — a machine must state its role, or eval
fails loudly (better than silently getting the wrong one).

## The three roles

`minimal` is the shared base every machine gets. `server` and `desktop` are
**mutually exclusive** extensions of it — a machine is one or the other, never a
"desktop that's also a server".

| role | what you get |
|---|---|
| `minimal` | the shared base: nix daemon (flakes, GC, build scheduling), sshd + hardening, sudo, `userborn`, networkd, sysctl network hygiene, firewall, serial console, deploy diff + hostname-change guard, terminfo, well-known git-forge host keys. No GUI, no headless-only opinions. |
| `server` | minimal **+** a hardened, headless posture: no docs/fonts/xdg, UTC, no suspend, watchdogs, immutable users, boot-generation limits, a baseline CLI toolkit (git/curl/htop/jq/tmux/dnsutils). No GUI. |
| `desktop` | minimal **+** the full GUI/agent stack: `pi-chat`, niri, noctalia, greetd autologin. |

## `default` vs `spaces` vs the leaf modules

- **`nixosModules.default`** — the base + role switch. Imports only the base
  modules, so it covers `minimal` and `server`. Preferred for servers.
- **`nixosModules.spaces`** — the desktop. Imports the GUI/agent module tree on
  top of `default` and selects `profile = "desktop"`. Import this for a desktop;
  it's also the back-compat alias existing importers already use.
- **`nixosModules.pi-chat`** (and the other leaf modules) — import a single piece
  onto a desktop you already run, no profile needed.

### Why the desktop modules aren't in `default`

NixOS `imports` can't depend on an option value, so a module listed in `default`
is imported for *every* profile — including `server`. Some GUI modules pull heavy
closures that stay in the system even when their service is disabled (most
sharply `pi-chat`, which imports `voxtype` whose ASR models — ~2.3 GiB — are
wired in unconditionally). Importing those in `default` would drag that weight
onto every headless host.

So the GUI modules (`pi-chat`, `llama-swap`, niri, noctalia, `vm-debug`) are
imported by `nixosModules.spaces`, not `default`. A `server`/`minimal` host
imports only the base and pulls in **zero** wayland/niri/greetd/voxtype closure.
The base modules that *are* in `default` (nix, serial, terminfo, …) are all
safe on any role.

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
