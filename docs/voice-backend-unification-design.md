# Voice Backend Unification — Shared whisper-server for voxtype + hermes

Date: 2026-07-16
Repos: spaces (this repo) + hyperconfig (hermes VM wiring)
Status: approved design, pre-implementation

## Problem

Two speech-to-text stacks run today on a spaces desktop that also hosts
hermes MicroVMs (hyperconfig's `hermes-microvm.nix`):

- **voxtype** (host dictation): whisper.cpp via whisper-rs FFI, in-process,
  vulkan GPU, Nix-fetched `ggml-small` model. Model resident in the daemon.
- **hermes voice mode** (inside the VM): faster-whisper on the **VM's CPU**.
  No GPU in the guest (host desktop owns the iGPU), so transcription is a
  major performance bottleneck — and it loads a *second* copy of a whisper
  model.

Both sides already speak the same protocol, unused:

- voxtype ships `[whisper] mode = "remote"` (`src/transcribe/remote.rs`):
  multipart POST to `{endpoint}/v1/audio/transcriptions`, expects `{text}`.
  Options: `remote_endpoint`, `remote_model`, `remote_api_key`,
  `remote_timeout_secs` (default 30).
- hermes ships `stt.provider = "openai"` + `STT_OPENAI_BASE_URL` env
  (`tools/transcription_tools.py`), posting to
  `{base}/audio/transcriptions`.

## Decisions (user-approved)

1. **Full unification**: one host whisper server; voxtype switches to
   remote mode against it; hermes VMs point at it via slirp `10.0.2.2`.
   Single model copy in memory.
2. **Always resident**: systemd service with the model loaded; no
   socket-activation, no llama-swap. Dictation latency stays instant.
3. **One blessed setup, zero new knobs**: enabling spaces voxtype always
   runs the server and always generates `mode = "remote"`. No local/remote
   configuration matrix.
4. **Placement**: server module + voxtype wiring in the spaces distro;
   hyperconfig only wires the hermes VMs.
5. **Hard requirement**: voxtype-tuner keeps working, including its model
   picker.

## Architecture

```
voxtype daemon (mode=remote) ──POST /v1/audio/transcriptions──▶ whisper-server
voxtype-tuner Apply ──writes user config, restart voxtype──▶ (PartOf= restarts server)
hermes VM (stt.provider=openai) ──10.0.2.2:8620──▶ whisper-server
whisper-server ──model resolved from effective voxtype config──▶ ggml model file
```

- **Server**: `whisper-cpp` from nixpkgs with `vulkanSupport = true`
  (builds `bin/whisper-server`, ffmpeg-wrapped on Linux, so non-wav uploads
  work). Run as a systemd **user** service under `default.target` — NOT
  the graphical session: hermes users have `linger` enabled and need STT
  for messaging voice notes with no desktop session. Listens on
  `127.0.0.1:8620` with `--inference-path /v1/audio/transcriptions`.
- **Model source of truth**: the server's ExecStart wrapper resolves the
  model from the *effective voxtype config* — user override at
  `$XDG_CONFIG_HOME/voxtype/config.toml` if present, else
  `/etc/xdg/voxtype/config.toml` — reading `whisper.model`. Catalog names
  (`tiny`, `base`, `small`, …) map to
  `~/.local/share/voxtype/models/ggml-<name>.bin`; absolute paths (Nix
  store models) pass through. This mirrors voxtype's own
  `resolve_model_path`.
- **Tuner compatibility (the crux)**: in remote mode the daemon ignores
  `whisper.model`, so an independently-configured server would turn the
  tuner's model picker into a silent lie. Instead the server *follows the
  config*: a systemd **path unit** watches
  `$XDG_CONFIG_HOME/voxtype/config.toml` (and the `/etc/xdg` config
  symlink) and restarts `whisper-server.service` on change. The tuner's
  existing "Apply → write user config → restart voxtype" therefore
  retargets the server onto the newly applied model with **zero tuner
  code changes** and without tying the server's lifecycle to
  `voxtype.service` (which stops on logout):
  - Apply's TOML emitter round-trips unknown keys verbatim
    (`packages/voxtype-tuner/tests/test_apply.py` pins "preserve EVERY
    baseline key"), so `mode`/`remote_endpoint` survive.
  - The Transcribe A/B button intentionally stays local in-process
    (`voxtype transcribe` subprocess): A/B across *different* models cannot
    run against a server holding exactly one model. Transient second model
    load while tuning is accepted.

## Changes — spaces

1. **New `modules/nixos/whisper-server.nix`**
   - User service `whisper-server.service`: `WantedBy=default.target`
     (linger-compatible; not graphical), `Restart=on-failure`.
     `voxtype.service` gains `Wants=whisper-server.service`.
   - Path unit `whisper-server-config.path`: `PathChanged=` on the user
     config and the generated `/etc/xdg/voxtype/config.toml`; triggers a
     oneshot restarting `whisper-server.service` (covers tuner Apply and
     nixos-rebuild config swaps).
   - ExecStart wrapper (small script; TOML read via python3 `tomllib`):
     resolve effective config → `whisper.model` → model path; exec
     `whisper-server --host 127.0.0.1 --port 8620 --inference-path
     /v1/audio/transcriptions -m <path>`.
   - Package: `pkgs.whisper-cpp.override { vulkanSupport = true; }`.
   - Enabled wherever the voxtype module is active (same import gate, no
     separate enable option).
2. **`modules/nixos/voxtype.nix`**
   - whisper `engineSettings` gain `mode = "remote"` and
     `remote_endpoint = "http://127.0.0.1:8620"`.
   - `whisper.model` stays — it is now the server's model source of truth
     and keeps the tuner picker meaningful.
3. **Checks** (existing spaces style)
   - nix-eval check: generated config.toml carries
     `whisper.mode = "remote"` + the endpoint, and still carries the model
     store path.
   - wrapper-behaviour check (stub server binary): catalog-name resolution,
     absolute-store-path passthrough, user-override-wins.
   - tuner pytest: Apply on a remote-mode baseline preserves
     `mode`/`remote_endpoint`/`remote_*` keys verbatim.

## Changes — hyperconfig

`modules/nixos/hermes-microvm.nix` (guest provisioning seam already used
for model config):

- Guest hermes settings: `stt.provider = "openai"`,
  `stt.openai.api_key = "local"` (whisper-server ignores auth; the key
  only satisfies hermes' non-empty check).
- Agent + gateway unit env: `STT_OPENAI_BASE_URL=http://10.0.2.2:8620/v1`.
- Wired unconditionally (not gated on `audio.enable`): STT also
  transcribes messaging-platform voice notes, which need no sound card.
- faster-whisper stays in the guest package (upstream dep); the explicit
  provider pin makes it inert.

## Failure modes

- **Server down**: voxtype take fails visibly (remote `NetworkError`),
  state file steps recording→idle, indicator shows the failed take.
  `systemctl --user restart whisper-server` (or a tuner re-Apply) brings
  it back; voxtype restarts pull it in via `Wants=`.
  Deliberately **no silent fallback** to local inference — consistent with
  the module's "visibly failing beats half-applied" philosophy.
- **Hermes**: openai-provider error surfaces in the voice loop / message
  handler; the VM keeps running.
- **Non-whisper engine applied via tuner** (parakeet/nemotron): daemon
  ignores `[whisper]` entirely and runs that engine locally, as today; the
  server idles (harmless).

## Accepted caveats

- `/v1/audio/translations` is not served (`--inference-path` maps one
  route); generated config pins `translate = false`.
- Fixed port 8620, one graphical user per host — same single-user caveat
  class `hermes-microvm.nix` already documents. Another local user (or
  another user's guest) can reach the STT port; transcription is
  low-sensitivity and matches the existing cross-VM caveat.
- Tuner A/B transiently loads a second model locally while tuning.

## Verification plan

- spaces: the three checks above pass; `nix flake check` untouched
  otherwise.
- hyperconfig: `nix eval` of the generated hermes guest config shows the
  STT provider + env.
- Live smoke on the desktop:
  `curl -F file=@take.wav -F model=x http://127.0.0.1:8620/v1/audio/transcriptions`,
  one dictation round-trip (Mod+S), one hermes voice round-trip in the VM,
  one tuner Apply with a model change followed by a dictation using the new
  model (server restart observed).
