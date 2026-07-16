# Voice Backend Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One always-resident whisper.cpp server on the host serves speech-to-text for both voxtype (host dictation, remote mode) and hermes VMs (openai STT provider via slirp), replacing two independent model loads.

**Architecture:** New spaces user-service `whisper-server` (vulkan whisper-cpp, `127.0.0.1:8620`, `--inference-path /v1/audio/transcriptions`) resolves its model from the *effective voxtype config* (user override else `/etc/xdg`); a path unit restarts it when that config changes, so voxtype-tuner Apply retargets it with zero tuner changes. voxtype's generated config flips to `mode = "remote"`. hyperconfig points hermes guests at `10.0.2.2:8620`.

**Tech Stack:** NixOS modules (spaces + hyperconfig), whisper-cpp (nixpkgs, `vulkanSupport = true`), systemd user units, blueprint-discovered `checks/`, pytest (voxtype-tuner).

**Spec:** `docs/voice-backend-unification-design.md` (spaces repo).

## Global Constraints

- Repos: spaces = `~/projects/spaces`, hyperconfig = `~/projects/hyperconfig`. Exact paths below are repo-relative.
- Zero new user-facing knobs: no enable option; server active whenever the spaces voxtype module is. The only new option is `spaces.whisper-server.port` with `internal = true` (cross-module single source of the port).
- Port `8620`, loopback only. Endpoint path `/v1/audio/transcriptions`.
- Server unit gated on `default.target` (linger-compatible), NEVER `graphical-session.target`.
- No silent fallback to local inference anywhere.
- Tuner code is untouched — only test fixtures/tests are added there.
- Version control: top-level executor uses `jj` (`jj new` per task, `jj describe` at end of task); subagents run NO version control.
- Do not run repo-wide formatters/linters/`nix flake check`; run only the named checks/tests per task.

---

### Task 1: whisper-server module (spaces)

**Files:**
- Create: `modules/nixos/whisper-server.nix`
- Create: `checks/whisper-server-wrapper/default.nix`
- Modify: `modules/nixos/voxtype.nix:342` (imports line: add `./whisper-server.nix`)

**Interfaces:**
- Consumes: `config.environment.etc."xdg/voxtype/config.toml"` (declared by `voxtype.nix`).
- Produces: user unit `whisper-server.service`; option `config.spaces.whisper-server.port` (int, default 8620, internal) — Task 2 references both; wrapper script `whisper-server-daemon` execs `whisper-server` **by name** (unit `path` pins the package) so checks can stub it, mirroring `daemonScript`/`voxtype`.

- [ ] **Step 1: Write the failing check**

`checks/whisper-server-wrapper/default.nix`:

```nix
# Wrapper-behaviour + unit-wiring contract for the shared STT server
# (modules/nixos/whisper-server.nix).
#
# The server must follow the EFFECTIVE voxtype config (user override at
# $XDG_CONFIG_HOME/voxtype/config.toml, else the generated /etc/xdg file):
# that is the whole tuner-compatibility story — tuner Apply writes the
# user file, the path unit restarts the server, the server re-resolves
# whisper.model. What a plain system build does NOT catch:
#
#   - a catalog name ("small") must resolve to
#     $XDG_DATA_HOME/voxtype/models/ggml-small.bin (or the ~/.local/share
#     default), an absolute store path must pass through verbatim;
#   - the user override must win over the system config;
#   - a missing model file must exit non-zero (visible unit failure, no
#     silent fallback);
#   - the unit must be linger-compatible: WantedBy default.target, NOT
#     graphical-session.target (hermes voice notes run headless);
#   - the path unit must watch both the user config and /etc/xdg copy.
#
# Runs the realised wrapper with a stubbed `whisper-server` capturing
# argv. ~1s, no VM, no whisper build (the wrapper execs by name).
{ pkgs, inputs, ... }:
let
  lib = pkgs.lib;
  system = inputs.self.lib.mkEvalSystem {
    modules = [
      inputs.self.nixosModules.spaces
      { networking.hostName = "whisper-server-wrapper"; }
    ];
  };
  unit = system.config.systemd.user.services.whisper-server;
  pathUnit = system.config.systemd.user.paths.whisper-server-restart;
  execStart = unit.serviceConfig.ExecStart;
  configToml = system.config.environment.etc."xdg/voxtype/config.toml".source;

  stubServer = pkgs.writeShellScriptBin "whisper-server" ''
    printf '%s\n' "$@" > "$ARGV_WITNESS"
  '';
in
pkgs.runCommand "whisper-server-wrapper-test"
  {
    inherit execStart configToml;
    wantedBy = builtins.toJSON unit.wantedBy;
    pathsWatched = builtins.toJSON pathUnit.pathConfig.PathChanged;
    nativeBuildInputs = [
      stubServer
      pkgs.python3
    ];
  }
  ''
    set -x
    # Unit wiring: linger-compatible, never graphical.
    [[ "$wantedBy" == '["default.target"]' ]]
    python3 - <<PY
    import json, os
    watched = json.loads(os.environ["pathsWatched"])
    assert any(p.endswith("/.config/voxtype/config.toml") or "%h" in p for p in watched), watched
    assert "/etc/xdg/voxtype/config.toml" in watched, watched
    PY

    export HOME=$PWD/home ARGV_WITNESS=$PWD/argv
    mkdir -p "$HOME"

    # (1) No user override: /etc/xdg is absent in the sandbox, so point the
    # wrapper's system fallback at the realised store config via the same
    # $WHISPER_SERVER_SYSTEM_CONFIG escape hatch the wrapper reads (defaults
    # to /etc/xdg/voxtype/config.toml). whisper.model is a store path in the
    # generated config: it must pass through verbatim... except the path does
    # not exist in the sandbox, so create a stand-in absolute model.
    mkdir -p "$PWD/models"
    : > "$PWD/models/ggml-fake.bin"
    cat > "$PWD/system-config.toml" <<EOF
    engine = "whisper"
    [whisper]
    model = "$PWD/models/ggml-fake.bin"
    EOF
    WHISPER_SERVER_SYSTEM_CONFIG=$PWD/system-config.toml $execStart
    grep -qx -- "$PWD/models/ggml-fake.bin" "$ARGV_WITNESS"
    grep -qx -- 8620 "$ARGV_WITNESS"
    grep -qx -- /v1/audio/transcriptions "$ARGV_WITNESS"
    grep -qx -- 127.0.0.1 "$ARGV_WITNESS"

    # (2) User override wins; catalog name resolves under XDG data dir.
    mkdir -p "$HOME/.config/voxtype" "$HOME/.local/share/voxtype/models"
    : > "$HOME/.local/share/voxtype/models/ggml-tiny.bin"
    cat > "$HOME/.config/voxtype/config.toml" <<EOF
    engine = "whisper"
    [whisper]
    model = "tiny"
    EOF
    WHISPER_SERVER_SYSTEM_CONFIG=$PWD/system-config.toml $execStart
    grep -qx -- "$HOME/.local/share/voxtype/models/ggml-tiny.bin" "$ARGV_WITNESS"

    # (3) Missing model file fails loudly.
    cat > "$HOME/.config/voxtype/config.toml" <<EOF
    engine = "whisper"
    [whisper]
    model = "medium"
    EOF
    if WHISPER_SERVER_SYSTEM_CONFIG=$PWD/system-config.toml $execStart; then
      echo "FAIL: missing model must exit non-zero" >&2; exit 1
    fi

    touch "$out"
  ''
```

- [ ] **Step 2: Run the check, verify it fails**

Run: `nix build ~/projects/spaces#checks.x86_64-linux.whisper-server-wrapper -L`
Expected: FAIL — `attribute 'whisper-server' missing` (unit not defined yet).

- [ ] **Step 3: Write the module**

`modules/nixos/whisper-server.nix`:

```nix
# Shared speech-to-text server: whisper.cpp `whisper-server` (vulkan) on
# 127.0.0.1:8620, serving the OpenAI-compatible /v1/audio/transcriptions
# route. One resident model copy for BOTH voxtype (whisper.mode = "remote",
# see ./voxtype.nix) and the hermes MicroVMs (hyperconfig points the guests'
# openai STT provider at slirp's 10.0.2.2:8620).
#
# Blessed setup, no knobs: imported (and thus always active) wherever the
# voxtype module is. The only option, `port`, is internal — a single source
# for voxtype.nix's remote_endpoint.
#
# Model source of truth: the EFFECTIVE voxtype config — the user override
# at $XDG_CONFIG_HOME/voxtype/config.toml (written by voxtype-tuner
# "Apply") if present, else the generated /etc/xdg/voxtype/config.toml.
# In remote mode the daemon ignores whisper.model, so an independently
# configured server would turn the tuner's model picker into a silent
# lie; resolving the model HERE, plus the path unit below restarting the
# server whenever either config file changes, keeps the picker honest
# with zero tuner code changes. Catalog names ("tiny", "small", ...)
# resolve like voxtype's own resolve_model_path
# ($XDG_DATA_HOME/voxtype/models/ggml-<name>.bin); absolute store paths
# pass through.
#
# Lifecycle: WantedBy=default.target, NOT graphical-session — hermes
# users linger and transcribe messaging voice notes with no desktop
# session. A missing model file is a visible unit failure (Restart
# loops), never a silent fallback to local inference — same philosophy
# as voxtype.nix's override handling.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.spaces.whisper-server;

  whisperServerPkg = pkgs.whisper-cpp.override { vulkanSupport = true; };

  # Execs `whisper-server` by name (pinned via the unit's path) so the
  # wrapper's closure stays tiny and checks can stub the binary — same
  # trick as voxtype.nix's daemonScript. $WHISPER_SERVER_SYSTEM_CONFIG is
  # a test seam: the sandbox has no /etc/xdg.
  daemonScript = pkgs.writeShellApplication {
    name = "whisper-server-daemon";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      user_config="''${XDG_CONFIG_HOME:-$HOME/.config}/voxtype/config.toml"
      config="''${WHISPER_SERVER_SYSTEM_CONFIG:-/etc/xdg/voxtype/config.toml}"
      if [ -f "$user_config" ]; then
        config="$user_config"
      fi
      model="$(python3 -c '
      import sys, tomllib
      with open(sys.argv[1], "rb") as f:
          cfg = tomllib.load(f)
      print(cfg.get("whisper", {}).get("model", "small"))
      ' "$config")"
      case "$model" in
        /*) model_path="$model" ;;
        *) model_path="''${XDG_DATA_HOME:-$HOME/.local/share}/voxtype/models/ggml-$model.bin" ;;
      esac
      if [ ! -f "$model_path" ]; then
        echo "whisper-server: model not found: $model_path (from $config)" >&2
        exit 1
      fi
      exec whisper-server \
        --host 127.0.0.1 \
        --port ${toString cfg.port} \
        --inference-path /v1/audio/transcriptions \
        -m "$model_path"
    '';
  };
in
{
  options.spaces.whisper-server = {
    port = lib.mkOption {
      type = lib.types.port;
      default = 8620;
      internal = true;
      description = ''
        Loopback port of the shared whisper-server. Internal: single
        source for voxtype.nix's remote_endpoint and the hermes guests'
        STT base URL (hyperconfig hardcodes 8620 — bump both together).
      '';
    };
  };

  config = {
    systemd.user.services.whisper-server = {
      description = "Shared whisper.cpp speech-to-text server (voxtype + hermes)";
      path = [ whisperServerPkg ];
      serviceConfig = {
        Type = "simple";
        ExecStart = lib.getExe daemonScript;
        Restart = "on-failure";
        RestartSec = 5;
      };
      wantedBy = [ "default.target" ];
    };

    # Tuner "Apply" writes the user config; nixos-rebuild swaps the
    # /etc/xdg symlink. Either way the server must re-resolve its model.
    systemd.user.paths.whisper-server-restart = {
      description = "Restart whisper-server when the voxtype config changes";
      pathConfig.PathChanged = [
        "%h/.config/voxtype/config.toml"
        "/etc/xdg/voxtype/config.toml"
      ];
      wantedBy = [ "default.target" ];
    };
    systemd.user.services.whisper-server-restart = {
      description = "Restart whisper-server after a voxtype config change";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "systemctl --user try-restart whisper-server.service";
      };
    };
  };
}
```

In `modules/nixos/voxtype.nix` change

```nix
  imports = [ inputs.voxtype.nixosModules.default ];
```

to

```nix
  imports = [
    inputs.voxtype.nixosModules.default
    ./whisper-server.nix
  ];
```

- [ ] **Step 4: Run the check, verify it passes**

Run: `nix build ~/projects/spaces#checks.x86_64-linux.whisper-server-wrapper -L`
Expected: PASS (derivation builds, `touch $out` reached).

If it fails on `--inference-path` never reaching the witness or the systemd module rejecting `%h` in `PathChanged`, fix forward: `%h` is a valid user-unit specifier; the stub captures argv one-per-line, so `grep -qx` matches exact lines.

- [ ] **Step 5: Verify the real binary + flags exist (one-off, not a check)**

Run:

```bash
nix build --no-link --print-out-paths --impure --expr \
  'with import <nixpkgs> {}; whisper-cpp' \
  && $(nix build --no-link --print-out-paths --impure --expr 'with import <nixpkgs> {}; whisper-cpp')/bin/whisper-server --help
```

Expected: help text listing `--host`, `--port`, `-m`, and `--inference-path`. If `--inference-path` is absent in the pinned nixpkgs version, STOP and flag — the endpoint contract depends on it. (Do NOT build the vulkan variant here; CPU build is enough to read `--help`.)

- [ ] **Step 6: Commit (spaces)**

```bash
cd ~/projects/spaces
jj describe -m "whisper-server: shared STT server module following the effective voxtype config"
jj new
```

---

### Task 2: voxtype goes remote (spaces)

**Files:**
- Modify: `modules/nixos/voxtype.nix:108-116` (whisper `engineSettings` branch), `modules/nixos/voxtype.nix:374-399` (voxtype unit gains `wants`)
- Create: `checks/voxtype-remote-config-nix-eval/default.nix`

**Interfaces:**
- Consumes: `config.spaces.whisper-server.port` (Task 1).
- Produces: generated `/etc/xdg/voxtype/config.toml` carrying `whisper.mode = "remote"` and `whisper.remote_endpoint = "http://127.0.0.1:8620"`; Task 3's fixtures and the hyperconfig smoke rely on exactly these keys.

- [ ] **Step 1: Write the failing check**

`checks/voxtype-remote-config-nix-eval/default.nix`:

```nix
# Cheap nix-eval contract for the voxtype remote-mode wiring
# (modules/nixos/voxtype.nix + modules/nixos/whisper-server.nix).
#
# The blessed setup transcribes through the shared whisper-server; the
# daemon's in-process whisper is dead code. What a plain system build
# does NOT catch:
#
#   - [whisper] mode must be "remote" — a typo silently keeps local
#     in-process transcription and a SECOND resident model copy;
#   - remote_endpoint must carry the whisper-server port (single source:
#     spaces.whisper-server.port);
#   - whisper.model must STAY the ggml store path: the server resolves
#     its model from this very file, and the tuner picker reads it;
#   - translate stays false ( --inference-path maps only the
#     transcriptions route; /v1/audio/translations would 404).
#
# Builds only the generated config.toml derivation, parses with tomllib.
# ~1s, no VM.
{ pkgs, inputs, ... }:
let
  system = inputs.self.lib.mkEvalSystem {
    modules = [
      inputs.self.nixosModules.spaces
      { networking.hostName = "voxtype-remote"; }
    ];
  };
  configToml = system.config.environment.etc."xdg/voxtype/config.toml".source;
  port = toString system.config.spaces.whisper-server.port;
in
pkgs.runCommand "voxtype-remote-config-nix-eval-test"
  {
    nativeBuildInputs = [ pkgs.python3 ];
    inherit configToml port;
  }
  ''
    python3 - <<'PY'
    import os, sys, tomllib

    with open(os.environ["configToml"], "rb") as f:
        cfg = tomllib.load(f)

    w = cfg["whisper"]
    assert cfg["engine"] == "whisper", cfg["engine"]
    assert w["mode"] == "remote", w
    assert w["remote_endpoint"] == f"http://127.0.0.1:{os.environ['port']}", w
    assert w["model"].startswith("/nix/store/"), w["model"]
    assert w["translate"] is False, w

    sys.stderr.write("PASS: voxtype config transcribes via the shared whisper-server\n")
    PY
    touch "$out"
  ''
```

- [ ] **Step 2: Run the check, verify it fails**

Run: `nix build ~/projects/spaces#checks.x86_64-linux.voxtype-remote-config-nix-eval -L`
Expected: FAIL — `KeyError: 'mode'`.

- [ ] **Step 3: Flip the generated config**

In `modules/nixos/voxtype.nix`, whisper branch of `engineSettings` (currently lines 108–116), replace:

```nix
    else
      {
        engine = "whisper";
        whisper = {
          language = cfg.whisperLanguage;
          model = toString models.${cfg.whisperModel};
          initial_prompt = cfg.initialPrompt;
        };
      };
```

with:

```nix
    else
      {
        engine = "whisper";
        whisper = {
          language = cfg.whisperLanguage;
          # The shared whisper-server (./whisper-server.nix) resolves ITS
          # model from this key — in remote mode the daemon itself ignores
          # it. Keeping the store path here is what keeps the tuner's
          # model picker honest (see the server module header).
          model = toString models.${cfg.whisperModel};
          initial_prompt = cfg.initialPrompt;
          # Blessed setup: always transcribe through the shared server —
          # one resident model for voxtype AND the hermes VMs. No local
          # fallback (a down server is a visible failure, not a silent
          # second model load). Remote mode uses only the primary
          # language of a whisperLanguage array (voxtype logs a warning).
          mode = "remote";
          remote_endpoint = "http://127.0.0.1:${toString config.spaces.whisper-server.port}";
        };
      };
```

In the `systemd.user.services.voxtype` block (after `partOf`, line ~377), add:

```nix
      # Dictation needs the shared STT server (config mode = "remote").
      wants = [ "whisper-server.service" ];
```

- [ ] **Step 4: Run the checks, verify they pass**

Run:
```bash
nix build ~/projects/spaces#checks.x86_64-linux.voxtype-remote-config-nix-eval -L
nix build ~/projects/spaces#checks.x86_64-linux.voxtype-language-config-nix-eval -L
nix build ~/projects/spaces#checks.x86_64-linux.voxtype-vad-config-nix-eval -L
nix build ~/projects/spaces#checks.x86_64-linux.voxtype-user-override-nix-eval -L
```
Expected: all PASS (the three existing voxtype config checks must not regress).

- [ ] **Step 5: Commit (spaces)**

```bash
cd ~/projects/spaces
jj describe -m "voxtype: transcribe through the shared whisper-server (mode = remote)"
jj new
```

---

### Task 3: tuner contract — remote keys survive Apply (spaces)

**Files:**
- Modify: `packages/voxtype-tuner/tests/test_apply.py` (extend `_SYSTEM_WHISPER_TOML` fixture + one new test)
- Modify: `packages/voxtype-tuner/tests/test_defaults.py` (same fixture extension)

**Interfaces:**
- Consumes: `apply.serialize_config(params, raw, store_path)`, `defaults._params_from_toml(raw)` — existing tuner API, unchanged.
- Produces: pinned regression: tuner Apply preserves `whisper.mode` / `remote_endpoint` verbatim. No production code.

- [ ] **Step 1: Update the fixtures to mirror the new module output**

Both `test_apply.py` (line ~30) and `test_defaults.py` (line ~33) declare `_SYSTEM_WHISPER_TOML` as "the file modules/nixos/voxtype.nix generates". Keep them honest: in BOTH files, inside the `[whisper]` table of `_SYSTEM_WHISPER_TOML` (after the `initial_prompt`/`language` lines, alongside `model = "/nix/store/...-ggml-small.bin"`), add:

```toml
mode = "remote"
remote_endpoint = "http://127.0.0.1:8620"
```

- [ ] **Step 2: Add the preservation test**

Append to `packages/voxtype-tuner/tests/test_apply.py`:

```python
def test_apply_preserves_remote_mode_keys_verbatim() -> None:
    # The blessed spaces setup transcribes through the shared
    # whisper-server: the system config carries whisper.mode = "remote"
    # and remote_endpoint. Apply must never strip or rewrite them — a
    # dropped mode key silently flips the daemon back to local
    # in-process whisper and a second resident model copy.
    p, raw = _seed(_SYSTEM_WHISPER_TOML)
    store_path = raw["whisper"]["model"]

    got = _parse(apply.serialize_config(p, raw, store_path))

    assert got["whisper"]["mode"] == "remote"
    assert got["whisper"]["remote_endpoint"] == "http://127.0.0.1:8620"
```

- [ ] **Step 3: Run the tuner tests**

Run (from `~/projects/spaces`, x86_64 devshell):
```bash
nix develop ~/projects/spaces#voxtype-tuner --command pytest packages/voxtype-tuner/tests/test_apply.py packages/voxtype-tuner/tests/test_defaults.py -q
```
Expected: PASS, including the new `test_apply_preserves_remote_mode_keys_verbatim` and every pre-existing round-trip test (they parse the fixture dynamically, so the added keys flow through `raw`).

If `test_defaults.py` fails on the new keys, that is a REAL finding (the loader chokes on remote-mode configs) — stop and report; do not paper over.

- [ ] **Step 4: Commit (spaces)**

```bash
cd ~/projects/spaces
jj describe -m "voxtype-tuner tests: pin that Apply preserves remote-mode keys"
jj new
```

---

### Task 4: hermes VMs use the host server (hyperconfig)

**Files:**
- Modify: `~/projects/hyperconfig/modules/nixos/hermes-agent.nix:64-99` (`services.hermes-microvm` block)
- Modify: `~/projects/hyperconfig/flake.lock` (spaces input bump, final step)

**Interfaces:**
- Consumes: host `whisper-server` on `127.0.0.1:8620` (Tasks 1–2); guest→host slirp alias `10.0.2.2`; hermes config keys `stt.provider`, `stt.openai.api_key` (`hermes_cli/config.py`), env `STT_OPENAI_BASE_URL` (`tools/transcription_tools.py:99`).
- Produces: guest hermes config with `stt.provider = "openai"`; guest env `STT_OPENAI_BASE_URL=http://10.0.2.2:8620/v1`.

- [ ] **Step 1: Wire settings + env**

In `~/projects/hyperconfig/modules/nixos/hermes-agent.nix`, inside `services.hermes-microvm = { ... }`, after the `settings.model` block (line ~75), add:

```nix
    # STT: transcribe through the host's shared whisper-server (spaces
    # whisper-server.nix, loopback :8620) instead of faster-whisper on the
    # guest's CPU — the VM has no GPU and in-guest whisper was the voice
    # bottleneck. "openai" + STT_OPENAI_BASE_URL (below) is hermes'
    # self-hosted-endpoint path; the api_key only satisfies the non-empty
    # check (the server ignores auth). Unconditional: STT also transcribes
    # messaging voice notes, no sound card needed (audio.enable is only
    # the mic/virtio-sound side).
    settings.stt = {
      provider = "openai";
      openai.api_key = "local";
    };
```

In `users.grmpf.environment` (line ~90), the attrset currently starts with `lib.optionalAttrs simplexCfg.enable (...)`. Restructure so the STT var is unconditional:

```nix
      environment = {
        # Host whisper-server via slirp's host alias (port: spaces
        # whisper-server.nix, internal option, hardcoded here).
        STT_OPENAI_BASE_URL = "http://10.0.2.2:8620/v1";
      }
      // lib.optionalAttrs simplexCfg.enable (
        {
          SIMPLEX_WS_URL = "ws://10.0.2.2:${toString simplexCfg.port}";
        }
        // lib.optionalAttrs (simplexCfg.allowedUsers != [ ]) {
          SIMPLEX_ALLOWED_USERS = lib.concatStringsSep "," simplexCfg.allowedUsers;
        }
      );
```

- [ ] **Step 2: Eval-verify against the LOCAL spaces checkout**

Run (from `~/projects/hyperconfig`):
```bash
nix eval --override-input spaces path:$HOME/projects/spaces --json \
  .#nixosConfigurations.amy.config.microvm.vms.hermes-grmpf.config.config.services.hermes-agent.settings.stt
nix eval --override-input spaces path:$HOME/projects/spaces --json \
  .#nixosConfigurations.amy.config.microvm.vms.hermes-grmpf.config.config.systemd.services --apply \
  'svcs: svcs.hermes-agent.environment.STT_OPENAI_BASE_URL or (throw "STT env missing")'
```
Expected: `{"openai":{"api_key":"local"},"provider":"openai"}` and `"http://10.0.2.2:8620/v1"`. If the second eval's attr path differs (env may land via the upstream module's EnvironmentFile/environment merge), locate the seam with `nix eval ... --apply 'svcs: builtins.attrNames svcs'` and assert wherever `SIMPLEX_WS_URL` already lands — STT must ride the same mechanism. Also confirm amy evaluates the spaces voxtype module (host side):
```bash
nix eval --override-input spaces path:$HOME/projects/spaces --json \
  .#nixosConfigurations.amy.config.spaces.whisper-server.port
```
Expected: `8620`.

- [ ] **Step 3: Push spaces, bump the input**

After Tasks 1–3 are merged/pushed in the spaces repo (user pushes or `jj git push` per repo convention):
```bash
cd ~/projects/hyperconfig && nix flake update spaces
```
Re-run the Step 2 evals WITHOUT `--override-input`; same expected output.

- [ ] **Step 4: Commit (hyperconfig)**

```bash
cd ~/projects/hyperconfig
jj describe -m "hermes: guest STT via the host's shared whisper-server (spaces voxtype unification)"
jj new
```

---

### Task 5: live smoke on amy

**Files:** none (verification only).

**Interfaces:**
- Consumes: everything above, deployed via `nixos-rebuild switch` (user-run if the session lacks privileges).

- [ ] **Step 1: Rebuild + unit health**

```bash
sudo nixos-rebuild switch --flake ~/projects/hyperconfig#amy
systemctl --user status whisper-server.service   # expect: active, log shows the ggml-small store path and a Vulkan device line
systemctl --user status voxtype.service          # expect: active
```
If the server log shows CPU-only ggml init, check `groups $USER` for `render` and GPU node perms (`ls -l /dev/dri/renderD*`) — a lingering headless session may lack the seat ACL; fix = `users.users.<user>.extraGroups = [ "render" ]` host-side (report before adding).

- [ ] **Step 2: Protocol smoke**

```bash
ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -ar 16000 -ac 1 /tmp/tone.wav
curl -sf -F file=@/tmp/tone.wav -F model=x http://127.0.0.1:8620/v1/audio/transcriptions
```
Expected: HTTP 200, JSON with a `text` field (content may be empty/hallucinated for a tone — only the shape matters).

- [ ] **Step 3: Dictation round-trip**

Mod+S, speak a sentence, Mod+S. Expected: text typed into the focused window; `journalctl --user -u voxtype -n 20` shows a remote transcription, NOT "Loading whisper model".

- [ ] **Step 4: Tuner follows-the-config round-trip**

Open voxtype-tuner → pick model `tiny` (download if needed) → Apply. Expected: `systemctl --user status whisper-server` shows a restart triggered by the path unit and the log now loads `ggml-tiny.bin`; a dictation still works. Then re-Apply `small` (the blessed default).

- [ ] **Step 5: Hermes voice round-trip**

In the hermes VM (via `hermes` CLI): send a voice note through a wired platform or run `/voice on` + push-to-talk. Expected: transcript arrives; `STT` errors absent from gateway logs; guest CPU stays idle during transcription (the load shows up in the host `whisper-server`).

- [ ] **Step 6: Final commit / wrap-up**

Any fixes found in Steps 1–5 land as their own described `jj` commits in the repo they touch. Report the observed latency difference for hermes voice (VM CPU vs host vulkan) in the final summary.
