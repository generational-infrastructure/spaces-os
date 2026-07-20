# Mnemonic restore

Status: implemented (keys + discovery); installer flow pending
Owner: zimbatm
Date: 2026-07-14 (revised 2026-07-16)

## Goal

Rebuild a machine — system config and user data — anywhere, by booting a generic
SpacesOS medium and typing one 24-word mnemonic. The mnemonic is the only human
secret; everything else is public data or derived from it.

## Non-goals

- Abstracting the data provider. The config repo (and through it the borg
  destinations) are still named endpoints.
- Zero-touch restore onto arbitrary hardware. disko + nixos-facter handle most of
  it; different firmware may need a fixup pass. Target: same-model replacement.

## Root of trust: keys from the mnemonic

The mnemonic is a 32-byte ed25519 seed (BIP39 entropy, melt-compatible):

```
master_seed = BIP39_entropy(24 words)
  ├─ identity   = Ed25519(master_seed)                                # SSH + age
  ├─ rendezvous = Ed25519(HKDF(seed, "spaces-restore-rendezvous-v1")) # signs the record
  ├─ manifest   = HKDF(seed, "spaces-restore-manifest-v1")            # XChaCha20-Poly1305 key
  └─ nostr      = secp256k1(HKDF(seed, "nostr-rendezvous-v1"))        # Nostr identity
```

- **identity** — the SSH key authorized on the backup host (bootstrap login), and
  via `ssh-to-age` a sops recipient that decrypts `vars/`. The recipient is
  byte-identical to what sops-nix computes.
- **rendezvous** — signs the record; derived separately so it's unlinkable to the
  identity key.
- HKDF info strings are versioned; bump the `-vN` suffix to rotate a key.

Everything else (borg passphrases, the shared backup-host key, host keys) is
sops-encrypted data in the config repo, decryptable with the age key — not derived.

## The record: a pointer to the config repo

The flake already holds every restore detail — the machine list, each borg repo
(`inventory.instances.borgbackup`), the disko layout. So the record only says
where the flake is:

```json
{ "version": 1, "config": "<git URL or Radicle RID>", "rev": "<pinned commit>" }
```

`config` may be a GitHub URL or a Radicle RID (self-authenticating, no public
DNS); `rev` pins a known-good commit. `clan` reads everything else once cloned.

On the wire the record is `{pk, seq, v, sig}`: the manifest JSON sealed with the
manifest key (pad → XChaCha20-Poly1305, fresh nonce) and signed by the rendezvous
key. It carries no secret.

## Discovery: Nostr

The record is published as a kind-30078 (NIP-78) replaceable event under the
derived secp256k1 key.

- `publish` reads the config repo's git origin (+ HEAD), so the URL is never typed.
- `resolve` fetches and decrypts the record from the mnemonic alone.
- Best-effort across a baked list of open public relays, with per-endpoint
  reporting; the freshest signature-valid record wins. A local file store is an
  optional offline copy.

The record is only a convenience — if every relay drops it, you type the git URL
at restore — so best-effort relays suffice and no anchor relay is needed.

## Restore chain

1. Boot the stock SpacesOS medium (or `nix run …#spaces-restore` from any NixOS).
2. Type the mnemonic → derive the keys.
3. `resolve` the config pointer (or type the git URL).
4. Clone the flake at `rev`; the identity SSH key handles a private remote / the
   backup host, and `export SOPS_AGE_KEY=$(spaces-restore age-identity)` decrypts
   `vars/`.
5. Choose: provision a new machine, or restore an existing one.
6. `clan machines install <m>` (facter → disko → nixos-install), then
   `clan backups restore <m>` pulls data from borg.

## Provisioning (once, up front)

- Add `spaces-restore derive | jq -r .identity_ssh` to the backup host's
  `authorized_keys` — the shared backup-host key lives inside the encrypted
  config, so the mnemonic key must get in on its own to fetch it.
- `clan secrets users add recovery $(spaces-restore derive | jq -r .age_recipient)`
  and re-encrypt, so the mnemonic can decrypt `vars/`.
- `spaces-restore publish` from the config repo (optional — lets you resolve the
  git URL instead of remembering it).

## The honest floor

- Memorized: the mnemonic. Nothing else.
- System residual: the public tooling (re-downloadable, or `nix run`) + a baked
  relay list + a git host for the config. The config host is the user's choice;
  Radicle avoids public DNS entirely.
- The record's durability is not critical — it only saves typing the git URL — so
  best-effort relay retention is fine.

## Status

- Done: the keys, the record, Nostr publish/resolve (verified against live public
  relays and a local nostr-rs-relay), age-recipient interop with `ssh-to-age`,
  54 unit tests. The nv1 disko layout boots in a disko VM test.
- Pending: the installer flow (new-vs-restore chooser), the clone + `ssh-to-age`
  glue, a `clan backups restore` rehearsal on a scratch target, and shipping the
  tooling in the stock ISO.
- Prerequisite: each machine must actually back up its data to borg and carry a
  `disko.nix`, or a restore stands up an empty, unpartitioned system.

## Related / future

Fleet internal comms should likewise avoid public DNS: a WireGuard mesh or Iroh
keyed by the same identity. Out of scope here.
