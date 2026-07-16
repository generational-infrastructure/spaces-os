# spaces-restore

Rebuild a machine from a single 24-word mnemonic. The mnemonic derives the keys;
the config is a git repo; the flake holds everything else (machines, borg
destinations, disko), so `clan` reads it once cloned.

```
gen-mnemonic   fresh 24-word phrase
derive         ssh line, age recipient, rendezvous + nostr pubkeys
age-identity   secret age key for SOPS_AGE_KEY at restore
publish        publish the config pointer (from the repo's git origin)
resolve        fetch the config pointer with just the mnemonic
```

## Restore runbook

Legend: ✅ proven · 🔧 mechanism exists, not yet rehearsed · ⛏️ not built.

### 0. Provisioning (do ONCE, ahead of time)

1. **Choose the recovery mnemonic**: `spaces-restore gen-mnemonic`. Memorise +
   paper. It is the only secret.
2. **Authorise the identity key on the backup host**: add
   `spaces-restore derive | jq -r .identity_ssh` to its `authorized_keys` — the
   restore host's SSH-in for borg. 🔧
3. **Add the age key as a sops `recovery` user** so the mnemonic can decrypt
   `vars/`: `clan secrets users add recovery $(spaces-restore derive | jq -r
   .age_recipient)` → re-encrypt. 🔧
4. **Publish the config pointer** (optional — lets you resolve the git URL from
   the mnemonic instead of remembering it): from the config repo,
   `spaces-restore publish` (reads git origin + HEAD, pushes to Nostr). ✅

### 1. Boot the medium

Stock SpacesOS ISO (ships `spaces-restore`), or `nix run
github:generational-infrastructure/spaces-os#spaces-restore` from any NixOS. No
per-user data on it. ✅ tooling on the ISO; ⛏️ guided installer flow.

### 2. Find the config

```
export SPACES_MNEMONIC='… 24 words …'
spaces-restore resolve            # → {"config":"github:you/flake","rev":"…"}
```
…or just type/paste the git URL (a Radicle RID or GitHub URL) if you'd rather not
depend on a relay. ✅ (resolve verified live)

### 3. Clone + unlock

```
git clone <config> && cd <repo> && git checkout <rev>   # identity ssh key if private
export SOPS_AGE_KEY=$(spaces-restore age-identity)       # decrypts vars/
```
🔧 (glue not yet scripted)

### 4. Choose: new machine, or restore existing

```
clan machines install <machine> --target-host root@<this-host>
```
facter re-detects hardware, disko partitions, `nixos-install`. Disko layout
(ESP + LUKS root + encrypted swap) ✅ rehearsed in a VM. Full install path 🔧.

### 5. Restore data

```
clan backups restore <machine> borgbackup <archive>
```
The borg destination is read from the flake's inventory — the record never stated
it. 🔧 (rehearse on a scratch target, never the live box).

### 6. Reboot

Into the restored system; `/run/secrets` decrypts with the machine key; LUKS root
prompts for its install-time passphrase.

## Proven vs not

- ✅ key derivation, publish/resolve of the config pointer (live Nostr), the disko
  layout (VM boot test).
- 🔧 the clone + ssh-to-age glue, `clan machines install` on bare metal,
  `clan backups restore` round-trip.
- ⛏️ the installer flow (new-vs-restore chooser) and the stock-ISO packaging.

**Rehearse before trusting:** run steps 4+5 against a throwaway target end-to-end.
