# Hermes agent port: hyperconfig → spaces

Date: 2026-07-22. Status: approved design, pre-plan.
Source: `~/synced/projects/hyperconfig/modules/nixos/hermes/` (14 files).
Destination: `modules/nixos/hermes/` in this repo, published as
`nixosModules.hermes` (blueprint auto-discovery).

## Problem

The hermes-agent microvm stack (per-user untrusted-agent VMs: vsock ssh
shims, dashboard forwarding, fw_cfg credential injection, virtiofs state
vault, iptables owner-match egress) lives in hyperconfig, a personal site
config. Spaces is the product repo — and the VMs already talk to spaces'
per-user integration gateway (`spacesGateway`). Port the module tree into
spaces as a first-class desktop feature; hyperconfig deletes its copy and
consumes the spaces module (move + consume, approach A, phased).

## Scope

**Phase 1 — faithful port.** Move the module tree unchanged in behavior.
**Phase 2 — productization.** Desktop default-on, auto-provisioning,
credential-only brain wiring, gateway auto-enable, docs, tests.
**Phase 3 — hyperconfig cutover.** Separate change in that repo.

**Dropped entirely (all phases): simplex.** `simplex-chat.nix`,
`simplex-chat-package.nix`, the `simplex.*` options, the DM-send fix
shadow plugin. None of it ports; hyperconfig's cutover removes its usage.

## Phase 1: faithful port

Ported files: `default.nix`, `options.nix` (minus `simplex.*`),
`host.nix`, `guest.nix` (minus simplex import/wiring), `guest-python.nix`,
`firewall.nix`, `cli.nix`, `scripts.nix`, `lib.nix`, `vms.nix`.
Not ported: `site.nix` (stays in hyperconfig), `guest-python-test.nix`
(subsumed by the heavy test, phase 2), simplex files.

Flake inputs added:
- `hermes-agent.url = "github:NousResearch/hermes-agent"` — **no**
  `nixpkgs.follows`: the pin carries its own uv2nix/pyproject python
  closure; re-basing risks wheel/ABI breakage and it only runs in guests.
- `microvm.url = "github:microvm-nix/microvm.nix"` with
  `nixpkgs.follows = "nixpkgs"` (host units must match our
  qemu/virtiofsd).

Option namespace stays `services.hermes-microvm`. Importing the module
with zero VM users adds no meaningful closure (guest toplevel and hermes
wheel are only referenced per declared user).

## Phase 2: productization

### Desktop composition

`modules/nixos/spaces.nix` imports `nixosModules.hermes`; under the
`desktop` profile gate: `services.hermes-microvm.enable = mkDefault true`.
Server/minimal never import it.

### Auto-provisioning

- `services.hermes-microvm.provisionNormalUsers` (bool, default `true`):
  every `isNormalUser` in `users.users` gets an auto-populated
  `users.<name>` entry.
- Per-user `users.<name>.enable` (default = `provisionNormalUsers`)
  overrides in either direction; explicit entries merge over auto ones.
- **uid assertion**: ports, vsock CID and MAC derive from uid at eval
  time. An auto-provisioned user without a declared
  `users.users.<n>.uid` fails eval with a message naming the fix.
  (Index-based allocation was rejected: it silently reshuffles VM
  identities — and their state vaults — when the user set changes.)

### Installer

The Calamares config-gen template (`packages/calamares-spaces-extensions/
files/main.py`, `cfgusers`) gains `uid = 1000;` for the primary user.
On a fresh install the first normal user deterministically receives 1000
(userborn/useradd), so this declares an inevitable fact and makes it
eval-visible; it also closes the existing divergence with
`hosts/test-machine` and `hosts/installer-target` (both hardcode 1000).
`debug/installer-config-gen/test_render.py` gets the matching assertion.

### Brain: credentials only, never a model pin

Upstream facts (rev 4425ddd, source-verified): Nix `settings.model` is
deep-merged into the guest's `config.yaml` on **every** activation, Nix
keys win — a Nix model pin permanently clobbers the user's runtime
choice. The TUI/CLI model selector persists into the same file via
ungated writes and survives reboots iff Nix sets no model keys. With no
model configured the gateway starts fine and falls back per-message to a
cost-safe catalog default for whatever provider the credentials imply.
Known upstream wart: the *dashboard* model selector does not persist
under managed mode (which the upstream module always enables); only
TUI `/model` and CLI switches stick.

Consequently the spaces module **never writes model keys**:

- New option `services.hermes-microvm.initialModel`
  (`nullOr` submodule `{ provider, base_url, default }`, default
  auto-derived). Consumed solely by a guest-side **seed-once** snippet
  ordered before upstream's config merge: written into `config.yaml`
  only when the file is absent. First boot seeds it; every later
  GUI/TUI change sticks.
- Derivation: `spaces.openrouter.enable` → `initialModel = null` (the
  key alone suffices; catalog default on first run). Else
  `services.llama-swap.enable` → `{ provider = "custom"; base_url =
  "http://10.0.2.2:<llama-swap port>/v1"; default = "gemma4:e4b"; }`
  (slirp host alias; `mkDefault`). Sites with bespoke endpoints set
  `initialModel` explicitly.
- Credentials: when `spaces.openrouter.enable`, every VM's
  `secretEnv.OPENROUTER_API_KEY = spaces.openrouter.apiKeyFile` (host
  path string → LoadCredential → fw_cfg → guest `.env` block, the
  existing pipeline).
- Gating: neither openrouter nor llama-swap nor explicit `initialModel`
  nor per-user `secretEnv` model credentials → **no VMs provisioned**,
  one eval warning. Shims stay installed (they fail informatively).
- Guard rail: assertion rejects `settings ? model` with a message
  pointing at `initialModel` (prevents reintroducing the boot-clobber).
- llama-swap brain additionally opens one egress rule in the
  `hermes-microvm` iptables chain: per-VM qemu uid → llama-swap port
  (currently only DNS + spaces bridge are allowed, so the local brain
  would otherwise be RST-rejected).

### Openrouter option rename

New options-only module `modules/nixos/openrouter.nix`:
`spaces.openrouter = { enable, apiKeyFile }`, imported from the base
tree (no closure). `services.pi-chat.openrouter.{enable,apiKeyFile}`
migrate via `mkRenamedOptionModule`; pi-chat reads the new path. The
`/run/spaces-secrets` staging service stays in pi-chat (delivery
detail); hermes uses the raw `apiKeyFile` path directly.

### Gateway

`users.<u>.spacesGateway.enable` defaults to whether the host enables
the spaces integration gateway (socket path default already matches:
`/run/user/<uid>/spaces-integration-gateway.sock`).

## Testing

Cheap (`checks/`, in `nix flake check`):
- `hermes-nix-eval` — synthetic desktop host eval: VM units, shims,
  firewall chain present; brain derivation picks openrouter-null vs
  llama-swap tuple correctly; negative: uid-less auto-user trips the
  assertion; negative: `settings.model` trips the guard rail.
- `hermes-openrouter-rename-eval` — old `services.pi-chat.openrouter.*`
  path still evaluates and lands in `spaces.openrouter.*`.

Heavy (`debug.x86_64-linux.hermes-vm`, on-demand, never in CI checks —
nested virt: inner qemu gets KVM only on nested-enabled hosts, TCG
fallback otherwise, minutes):
- Desktop node, hermes default-on, uid-1000 user, dummy openrouter key
  file (satisfies brain gating; gateway tolerates a bogus key at boot).
- Wait `microvm@hermes-<user>`; exercise real interfaces: host `hermes`
  shim → vsock ssh → guest CLI probe; dashboard forward socket answers.
- Guest-python probes (from hyperconfig's `guest-python-test.nix`) run
  over ssh against the real guest: login-shell python/pip resolve to the
  writable venv, PATH order, `pip install` works, LD_LIBRARY_PATH set.
- `checks/hermes-guest-python` is deliberately **not** ported separately.

## Phase 3: hyperconfig cutover (separate repo/change)

- Bump the `spaces` input; delete `modules/nixos/hermes/` except
  `site.nix`.
- `site.nix`: import `inputs.spaces.nixosModules.hermes`; keep clan vars
  + `secretEnv` (openrouter + telegram, unchanged); replace
  `settings.model` (vit.d) with `initialModel`; drop `simplex.enable`
  and the simplex DM-fix shadow plugin.
- Non-destructive: amy's existing guest `config.yaml` already has a
  persisted model, so seed-once won't touch it.
- Verify: `nix build` of amy's toplevel.

## Docs

`docs/hermes.md`: architecture summary (condensed from the module's
`default.nix` header), default-on/uid/brain rules, the
dashboard-selector-persistence upstream caveat.

## Accepted tradeoffs

- Dashboard model switching silently non-persistent (upstream managed
  mode); TUI/CLI persist. Documented, not worked around.
- `hermes-agent` input not following our nixpkgs: two nixpkgs in the
  lock, in exchange for an upstream-tested python closure.
- Heavy test is opt-in (`debug.*`), so full-boot regressions surface
  only when someone runs it — the price of nested-virt runtimes.
