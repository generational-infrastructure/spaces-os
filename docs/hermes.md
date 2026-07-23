# Hermes agent microvms

Per-user untrusted-agent VMs (NousResearch hermes-agent under
microvm.nix/qemu): slirp egress, vsock channels, fw_cfg credential
injection, virtiofs state vault, iptables owner-match dashboard gating.
Default-on under the desktop profile; every isNormalUser gets a VM
(opt out per user: `services.hermes-microvm.users.<n>.enable = false`,
globally: `provisionNormalUsers = false`).

## Identity: hash of the username, never a uid

No static uids anywhere (userborn does not reserve declared uids before
dynamic allocation — nikstur/userborn#59 — so declaring them is a
login-breaking hazard). Instead, `h = first 8 hex chars of
sha256(username)` derives:

| value | formula |
|---|---|
| vsock CID | `3 + h mod (2^32 − 4)` |
| MAC | `02:00:` + the 4 hash bytes |
| spaces bridge vsock port | `1024 + h mod (2^32 − 1024)` |
| dashboardPort default | `22100 + h mod 1000` (overridable option) |

Uniqueness is asserted at eval; a dashboardPort window collision names
both users and the override. Runtime uid uses resolve at service start:
iptables matches `--uid-owner <username>`, the bridge helper resolves
`/run/user/<euid>/…`, virtiofsd maps guest uid 1000 to the share
owner's uid via `--translate-uid map:1000:$(stat -c %u <share>):1`
(guest accounts are pinned to uid 1000).

## Channels

- `hermes` CLI → ssh over vsock (CID above) into the guest.
- Dashboard: loopback TCP `dashboardPort` → socat → vsock :9119.
  TCP because upstream's Electron client and dashboard server are
  strictly http(s)://host:port (source-verified rev 3ef6bbd); upstream
  disables auth on loopback binds, so the host-side iptables owner
  match IS the auth. Known upstream wart: the dashboard model selector
  does not persist under managed mode; TUI `/model` and CLI switches do.
- Spaces gateway: guest MCP socat `VSOCK-CONNECT:2:<port>` → host
  AF_VSOCK socket unit → per-connection helper that REJECTS any peer
  CID other than the owner's VM (vsock has no file permissions and no
  netfilter — the hypervisor-guaranteed peer CID is the access
  control), then splices to the owner's gateway unix socket.

## Brain rules

- `spaces.openrouter.enable` → credentials only (`OPENROUTER_API_KEY`
  via fw_cfg), `initialModel = null`, catalog default on first run.
- `services.llama-swap.enable` → seed-once
  `{ provider = "custom"; base_url = "http://10.0.2.2:<port>/v1"; }`
  plus a per-VM egress rule; both on → llama wins the seed.
- `settings.model` is an eval error: Nix model keys re-merge on every
  boot and would clobber the user's runtime choice. `initialModel`
  seeds only when no config.yaml exists.

## State-vault invariant

Never open the state-vault sqlite DBs from the host while a VM runs:
WAL on virtiofs is only guest-coherent.
