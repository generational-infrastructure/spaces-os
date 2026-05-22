# NixOS VM test for the test-machine host.
#
# Dual-mode: defaults to the local llama-swap backend; if the
# `OPENROUTER_API_KEY` environment variable is set at eval time, the
# test switches pi-chat to the openrouter provider and runs a real
# round-trip against api.openrouter.ai instead.
#
#   nix build .#checks.x86_64-linux.test-machine                  # local
#   nix build --impure .#checks.x86_64-linux.test-machine          # local (env unset)
#   OPENROUTER_API_KEY=sk-or-... nix build --impure ...            # openrouter
#
# Reading the env var requires `--impure`; under `nix flake check`
# (pure eval) the key is invisible and the test always runs in local
# mode. Repo-local secret loading via direnv is documented in
# `README.md` and `.env.example`.
#
# Headless verification of the wiring around niri, the noctalia chat
# plugin, the pi-chat NixOS module, and llama-swap (or openrouter):
#   - greetd starts and opens a PAM session for the test user
#   - the user manager (user@1000.service) comes up
#   - niri.service activates and exposes a Wayland socket
#   - noctalia-shell.service starts under graphical-session.target
#   - the chat plugin is symlinked into the test user's noctalia dir
#   - the pi-chat user services come up (skill-config-daemon, …)
#   - the test user can send a message through the plugin IPC and the
#     pi process spawned under systemd-run replies (via local model or
#     openrouter, depending on mode)
#   - a second session can be minted via IPC and is isolated from the
#     first
#
# Interactive validation of the shell happens in the GUI VM
# (`nix build .#test-vm && ./result/bin/run-test-machine-vm`).
{ pkgs, inputs, ... }:

let
  inherit (pkgs) lib;

  openrouterKey = builtins.getEnv "OPENROUTER_API_KEY";
  useOpenrouter = openrouterKey != "";

  # Small, cheap, fast. Swap to taste; the round-trip only asserts a
  # non-empty reply, not specific content.
  openrouterModel = "google/gemma-4-26b-a4b-it";

  apiKeyFile = if useOpenrouter then pkgs.writeText "openrouter-api-key" openrouterKey else null;

  testPiChat = ./test-pi-chat.py;
  testPiMemory = ./test-pi-memory.py;
  mockLlm = ./test-machine-mock-llm.py;

  # Python helper that strips the pi-chat bar widget from every section
  # of ~/.config/noctalia/settings.json. Used by the regression subtest
  # that simulates a host whose persisted settings.json predates the
  # autoload widget-placement logic.
  stripPiChatWidget = pkgs.writeText "strip-pi-chat-widget.py" ''
    import json
    p = "/home/test/.config/noctalia/settings.json"
    d = json.load(open(p))
    w = d.setdefault("bar", {}).setdefault("widgets", {})
    for s in ("left", "center", "right"):
        w[s] = [x for x in w.get(s, []) if x.get("id") != "plugin:pi-chat"]
    json.dump(d, open(p, "w"))
  '';

  baseTest = pkgs.testers.runNixOSTest {
    name = "test-machine${lib.optionalString useOpenrouter "-openrouter"}";
    node.specialArgs = { inherit inputs; };
    # Required because `nixosModules.noctalia` registers an overlay via
    # `nixpkgs.overlays`; runNixOSTest's default (pkgsReadOnly=true)
    # would make that assignment fail.
    node.pkgsReadOnly = false;

    nodes.test-machine =
      { lib, pkgs, ... }:
      {
        imports = [
          inputs.self.nixosModules.distro
          ../hosts/test-machine/configuration.nix
        ];

        # The host pins a real disk; the test framework provides its own.
        fileSystems = lib.mkForce { };
        boot.loader.systemd-boot.enable = lib.mkForce false;

        virtualisation = {
          memorySize = 4096;
          cores = 4;
          writableStore = true;
        };

        environment.systemPackages = [
          pkgs.python3
          pkgs.curl
        ];

        # Openrouter mode: switch provider/model and give the VM
        # outbound internet via a second user-mode NIC so it can reach
        # api.openrouter.ai. The first NIC stays on the test driver's
        # vlan for the python harness <-> machine plumbing.
        # Test-only: in local mode pi-chat would otherwise hit real
        # llama-swap on this VM. Cold-prefilling pi's multi-thousand
        # token system prompt on qwen2.5:0.5b under QEMU CPU blows
        # past any reasonable subtest budget. Substitute an
        # OpenAI-compatible mock that replies in milliseconds — the
        # round-trip test only checks plumbing, not model quality.
        services.pi-chat = {
          skills = lib.mkForce { };
          extensions = {
            bash-confirm = false;
          };
        }
        // lib.optionalAttrs useOpenrouter {
          defaultProvider = "openrouter";
          defaultModel = openrouterModel;
          openrouter.enable = true;
          openrouter.apiKeyFile = apiKeyFile;
        };

        services.llama-swap.enable = lib.mkIf (!useOpenrouter) (lib.mkForce false);

        systemd.services.test-mock-llm = lib.mkIf (!useOpenrouter) {
          description = "OpenAI-compatible mock LLM for the chat round-trip test";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = "${pkgs.python3}/bin/python3 ${mockLlm}";
            Restart = "no";
          };
        };

        # nixosTest's default networking is QEMU user-mode (gateway
        # 10.0.2.2, DNS 10.0.2.3). Enable DHCP and bypass NetworkManager
        # so the VM has outbound internet for api.openrouter.ai.
        networking = lib.mkIf useOpenrouter {
          useDHCP = lib.mkForce true;
          nameservers = lib.mkForce [ "10.0.2.3" ];
        };
        environment.etc = lib.mkIf useOpenrouter {
          "resolv.conf".text = lib.mkForce "nameserver 10.0.2.3\n";
        };
      };

    testScript =
      { nodes, ... }:
      let
        uid = toString nodes.test-machine.users.users.test.uid;
        modeArg = if useOpenrouter then "openrouter" else "local";
        noctaliaBin = "noctalia-shell";
        target = "plugin:pi-chat";
      in
      ''
        machine.wait_for_unit("multi-user.target")

        ${lib.optionalString useOpenrouter ''
          with subtest("VM has outbound internet (openrouter mode)"):
              machine.wait_until_succeeds(
                  "curl --silent --fail --max-time 10 https://openrouter.ai/api/v1/models > /dev/null",
                  timeout=20,
              )
        ''}

        with subtest("greetd autostarts the niri session"):
            machine.wait_for_unit("greetd.service")
            machine.wait_until_succeeds(
                "systemctl is-active user@${uid}.service",
                timeout=30,
            )

        with subtest("niri.service starts under the user manager"):
            machine.wait_until_succeeds(
                "systemctl --user --machine=test@.host is-active niri.service",
                timeout=30,
            )

        with subtest("niri exposes its Wayland socket"):
            machine.wait_for_file("/run/user/${uid}/wayland-1", timeout=30)

        with subtest("noctalia-shell is running"):
            machine.wait_until_succeeds(
                "systemctl --user --machine=test@.host is-active noctalia-shell.service",
                timeout=30,
            )
            machine.wait_until_succeeds(
                "test -d /run/user/${uid}/quickshell",
                timeout=30,
            )

        with subtest("chat plugin is autoloaded"):
            # New layout: the pi-chat module materializes the plugin
            # as a writable COPY (fresh mtimes) — not a /nix/store
            # symlink — so Qt's qmlcache invalidates properly. Assert
            # the copy exists and has a current mtime so a regression
            # to L+ symlinks trips this subtest, not the IPC audit.
            machine.wait_until_succeeds(
                "test -d /home/test/.config/noctalia/plugins/pi-chat "
                "&& test ! -L /home/test/.config/noctalia/plugins/pi-chat",
                timeout=30,
            )
            machine.wait_until_succeeds(
                "test -L /home/test/.config/noctalia/plugins-autoload/pi-chat",
                timeout=30,
            )
            mtime = int(machine.succeed(
                "stat -c %Y /home/test/.config/noctalia/plugins/pi-chat/Main.qml"
            ).strip())
            if mtime < 1_577_836_800:  # 2020-01-01
                raise Exception(
                    f"plugin Main.qml has nix-store epoch mtime ({mtime}); "
                    "Qt qmlcache will pin stale bytecode across rebuilds"
                )

        with subtest("pi-chat user services come up"):
            machine.wait_until_succeeds(
                "systemctl --user --machine=test@.host is-active distro-skill-config-daemon.service",
                timeout=30,
            )
            machine.wait_for_file(
                "/run/user/${uid}/distro-skill-config.sock", timeout=30
            )

        with subtest("pi-agent config dir is materialized"):
            machine.wait_until_succeeds(
                "test -f /home/test/.local/state/distro/pi/pi-agent/settings.json",
                timeout=30,
            )
            machine.succeed(
                "grep -q 'llama-swap-discover' /home/test/.local/state/distro/pi/pi-agent/settings.json"
            )

        with subtest("llama-swap is up"):
            machine.wait_for_open_port(8012, timeout=120)

        with subtest("plugin loaded into noctalia"):
            # plugins.json is written by noctalia once it has scanned
            # the plugin directory. If the QML failed to compile, the
            # file is still written but the chat plugin won't be
            # listed as enabled. Fail fast and dump diagnostics so we
            # don't waste the test budget polling a dead IPC handler.
            machine.wait_for_file(
                "/home/test/.config/noctalia/plugins.json", timeout=60
            )
            import time as _time
            _time.sleep(3)  # noctalia scans plugins async after startup
            plugins_raw = machine.succeed(
                "cat /home/test/.config/noctalia/plugins.json"
            )
            import json as _json
            plugins = _json.loads(plugins_raw)
            states = plugins.get("states", {})
            enabled = any(
                s.get("enabled") is True
                for k, s in states.items()
                if "pi-chat" in k
            )
            if not enabled:
                machine.execute(
                    "journalctl --user --machine=test@.host "
                    "--no-pager -b 2>&1 | tail -200 || true"
                )
                raise Exception(
                    f"chat plugin failed to auto-enable in noctalia: {plugins_raw}"
                )

        def settings_widget_ids():
            raw = machine.succeed(
                "cat /home/test/.config/noctalia/settings.json"
            )
            data = _json.loads(raw)
            widgets = data.get("bar", {}).get("widgets", {})
            ids = []
            for section in ("left", "center", "right"):
                for w in widgets.get(section, []):
                    if isinstance(w, dict) and "id" in w:
                        ids.append((section, w["id"]))
            return ids

        with subtest("pi-chat bar widget is placed in the center section"):
            # PluginAutoload.qml places the chat widget in `center` on
            # first autoload. Settings.data persists to settings.json
            # asynchronously after addWidgetToBar mutates it.
            import time as _time
            deadline = _time.monotonic() + 60
            placement = None
            while _time.monotonic() < deadline:
                for section, wid in settings_widget_ids():
                    if wid == "plugin:pi-chat":
                        placement = section
                        break
                if placement:
                    break
                _time.sleep(0.5)
            if placement != "center":
                raise Exception(
                    f"pi-chat bar widget not in center; saw placement={placement!r} "
                    f"widgets={settings_widget_ids()}"
                )

        with subtest("widget is re-placed when stripped from settings.json on restart"):
            # Regression for the case where plugins.json
            # already records pi-chat (so the original "first-discovery
            # only" code path skipped widget placement), but the bar
            # widget is no longer in settings.json. Patched
            # PluginAutoload must re-add it on the next noctalia start.
            machine.copy_from_host(
                "${stripPiChatWidget}", "/tmp/strip-pi-chat-widget.py"
            )
            machine.succeed(
                "systemctl --user --machine=test@.host stop noctalia-shell.service"
            )
            machine.succeed(
                "sudo -u test python3 /tmp/strip-pi-chat-widget.py"
            )
            ids_after_strip = [
                wid for _section, wid in settings_widget_ids()
                if wid == "plugin:pi-chat"
            ]
            if ids_after_strip:
                raise Exception(
                    f"sanity: pi-chat widget still present after strip: {ids_after_strip!r}"
                )
            machine.succeed(
                "systemctl --user --machine=test@.host start noctalia-shell.service"
            )
            machine.wait_until_succeeds(
                "systemctl --user --machine=test@.host is-active noctalia-shell.service",
                timeout=30,
            )
            deadline = _time.monotonic() + 60
            restored = None
            while _time.monotonic() < deadline:
                for section, wid in settings_widget_ids():
                    if wid == "plugin:pi-chat":
                        restored = section
                        break
                if restored:
                    break
                _time.sleep(0.5)
            if restored != "center":
                raise Exception(
                    "patched noctalia did not re-place the pi-chat bar widget; "
                    f"saw placement={restored!r} widgets={settings_widget_ids()}"
                )

        with subtest("plugin-sync wipes legacy entries from plugins-autoload"):
            # Mirrors the case where a previous distro
            # generation wrote `~/.config/noctalia/plugins-autoload/<old-id>`
            # symlinks (the plugin was renamed at some point) and the
            # current generation has no record of them. distro owns this
            # directory exclusively, so plugin-sync must wipe it on every
            # run and re-materialize just the currently-shipped ids.
            # Without that wipe the legacy symlinks survive forever:
            # PluginAutoload's GC only drops a plugins.json entry when
            # its manifest is gone from the autoload dir, so a live
            # symlink to a still-resident /nix/store path keeps the
            # ghost entry alive across reboots.
            machine.succeed(
                "systemctl --user --machine=test@.host stop noctalia-shell.service"
            )
            # Plant a legacy autoload symlink. Its target only needs to
            # carry a manifest.json so a naive (no-wipe) plugin-sync run
            # would leave it intact and PluginAutoload would treat it as
            # live. Reuse the materialized pi-chat dir for that.
            machine.succeed(
                "sudo -u test ln -sfn "
                "/home/test/.config/noctalia/plugins/pi-chat "
                "/home/test/.config/noctalia/plugins-autoload/opencrow-chat"
            )
            # Plant a matching plugins.json entry to verify Layer-1 GC
            # also drops it once the symlink is gone.
            machine.succeed(
                "sudo -u test python3 -c \""
                "import json; "
                "p='/home/test/.config/noctalia/plugins.json'; "
                "d=json.load(open(p)); "
                "d.setdefault('states', {})['opencrow-chat']="
                "{'enabled': True, 'autoload': True, "
                "'sourceUrl': 'https://github.com/noctalia-dev/noctalia-plugins'}; "
                "json.dump(d, open(p, 'w'))\""
            )
            machine.succeed(
                "test -L /home/test/.config/noctalia/plugins-autoload/opencrow-chat"
            )

            machine.succeed(
                "systemctl --user --machine=test@.host restart "
                "distro-pi-chat-plugin-sync.service"
            )
            # Sync wiped the legacy symlink; pi-chat's symlink survives.
            machine.fail(
                "test -e /home/test/.config/noctalia/plugins-autoload/opencrow-chat"
            )
            machine.succeed(
                "test -L /home/test/.config/noctalia/plugins-autoload/pi-chat"
            )

            machine.succeed(
                "systemctl --user --machine=test@.host start noctalia-shell.service"
            )
            machine.wait_until_succeeds(
                "systemctl --user --machine=test@.host is-active noctalia-shell.service",
                timeout=30,
            )
            # PluginAutoload's GC runs on first scan after start and
            # rewrites plugins.json without the legacy id.
            import time as _time
            deadline = _time.monotonic() + 60
            cleaned = False
            while _time.monotonic() < deadline:
                raw = machine.succeed(
                    "cat /home/test/.config/noctalia/plugins.json"
                )
                if "opencrow-chat" not in _json.loads(raw).get("states", {}):
                    cleaned = True
                    break
                _time.sleep(0.5)
            if not cleaned:
                raise Exception(
                    "plugins.json still references opencrow-chat after wipe + restart: "
                    + machine.succeed("cat /home/test/.config/noctalia/plugins.json")
                )

        with subtest("plugin IPC verbs are registered"):
            # ipc show enumerates every IpcHandler target the running
            # daemon has bound. If our plugin's QML threw at load time
            # the target will be missing — dump every diagnostic the
            # quickshell binary exposes (instance list + per-instance
            # log) and bail immediately so the failure mode is loud.
            sudo_env = (
                "sudo -u test "
                "HOME=/home/test "
                "XDG_RUNTIME_DIR=/run/user/${uid} "
                "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus "
                "WAYLAND_DISPLAY=wayland-1 "
            )
            code, ipc_out = machine.execute(
                sudo_env + "${noctaliaBin} ipc show 2>&1"
            )
            if code != 0 or "${target}" not in ipc_out:
                # Quickshell knows about every shell instance — even ones
                # whose QML aborted partway. `list -a --json` reports them
                # with pid/path; `log -i <id>` prints the captured stderr
                # including the QML traceback we actually want to see.
                _, instances_raw = machine.execute(
                    sudo_env + "${noctaliaBin} list -a --json 2>&1"
                )
                machine.log("== noctalia instances ==\n" + instances_raw)
                # The instance is alive but `log -i`/`ipc` can't find
                # its runtime files. Each dump is its own machine.execute
                # so a buffer fill in one doesn't truncate the rest.
                _, env_dump = machine.execute(
                    "pid=$(pgrep -f noctalia-shell | head -1); "
                    "echo PID=$pid; "
                    "tr '\\0' '\\n' < /proc/$pid/environ 2>/dev/null "
                    "| grep -E '^(XDG_|HOME|DBUS|WAYLAND)' "
                    "|| echo '<no env>'"
                )
                machine.log("== noctalia pid env ==\n" + env_dump)
                _, qs_tree = machine.execute(
                    "find /run/user/${uid}/quickshell -mindepth 1 "
                    "-printf '%p\\t%y\\t%s\\n' 2>&1 || true"
                )
                machine.log("== quickshell runtime tree ==\n" + qs_tree)
                _, all_socks = machine.execute(
                    "find /run/user/${uid} -type s -o -name '*.qslog' "
                    "-o -name '*.sock' 2>&1 | head -50"
                )
                machine.log("== all sockets/qslogs under /run/user/${uid} ==\n" + all_socks)
                # Read the per-instance log.log (plaintext) directly
                # as root — sudo's env stripping might be the only
                # reason `noctalia-shell log -i` failed earlier.
                _, raw_log = machine.execute(
                    "for f in /run/user/${uid}/quickshell/by-id/*/log.log; do "
                    "  echo === $f ===; "
                    "  tail -200 \"$f\" 2>&1; "
                    "done"
                )
                machine.log("== quickshell raw log.log ==\n" + raw_log)
                try:
                    inst_list = _json.loads(instances_raw)
                except Exception:
                    inst_list = []
                for inst in inst_list:
                    iid = inst.get("id") or ""
                    if not iid:
                        continue
                    _, log_dump = machine.execute(
                        sudo_env
                        + f"${noctaliaBin} log -i {iid} 2>&1 | tail -200"
                    )
                    machine.log(f"== noctalia log {iid} ==\n" + log_dump)
                machine.execute(
                    "journalctl --user --machine=test@.host "
                    "--no-pager -b | tail -200 || true"
                )
                raise Exception(
                    f"plugin IPC target ${target} missing (exit={code}):\n{ipc_out}"
                )
            machine.succeed(
                sudo_env + "${noctaliaBin} ipc call ${target} listSessions"
            )

        with subtest("chat round-trip through plugin IPC"):
            machine.copy_from_host("${testPiChat}", "/tmp/test-pi-chat.py")
            # systemd-run --user requires XDG_RUNTIME_DIR + a live user
            # manager. pam_systemd sets the former during the niri login,
            # so we just have to propagate it when invoking as the test
            # user from the test driver (which runs as root).
            code, ptest_out = machine.execute(
                sudo_env + "python3 /tmp/test-pi-chat.py "
                "${noctaliaBin} ${target} ${modeArg} 2>&1"
            )
            if code != 0:
                # Pi spawn lives in a per-session systemd scope; surface
                # the scope state plus its journal so silent pi failures
                # are visible at the first run rather than via timeout.
                # `;` chains after sudo bleed back to root, so each
                # diagnostic that needs the test user gets its own call.
                _, units = machine.execute(
                    sudo_env
                    + "systemctl --user list-units 'pi-chat-*' --all 2>&1"
                )
                machine.log("== pi-chat units ==\n" + units)
                _, j = machine.execute(
                    sudo_env
                    + "journalctl --user -b --no-pager -u 'pi-chat-*.service' "
                    "2>&1 | tail -100"
                )
                machine.log("== pi-chat scope journal ==\n" + j)
                _, noctalia_log = machine.execute(
                    "tail -80 /run/user/${uid}/quickshell/by-id/*/log.log 2>&1"
                )
                machine.log("== noctalia plaintext log ==\n" + noctalia_log)
                _, cfg_dump = machine.execute(
                    "cat /etc/distro/pi-chat.json 2>&1"
                )
                machine.log("== /etc/distro/pi-chat.json ==\n" + cfg_dump)
                raise Exception(
                    "chat round-trip failed (exit={}):\n{}".format(code, ptest_out)
                )

        with subtest("pi-chat scope tagged with the session id"):
            # The round-trip subtest exchanged messages on the original
            # session, which spawned a pi-chat-<sid>.service. A later
            # newSession call switches activeSessionId before we get
            # here, so don't rely on "active" — look for any session
            # that has a matching service unit.
            sessions_json = machine.succeed(
                sudo_env + "${noctaliaBin} ipc call ${target} listSessions"
            )
            import json as _json
            sessions = _json.loads(sessions_json or "[]")
            assert sessions, f"no sessions returned: {sessions_json!r}"
            picked = None
            for s in sessions:
                sid = s['id']
                code, _output = machine.execute(
                    f"systemctl --user --machine=test@.host show "
                    f"pi-chat-{sid}.service --property=LoadState "
                    f"| grep -q '^LoadState=loaded'"
                )
                if code == 0:
                    picked = sid
                    break
            assert picked, f"no pi-chat-*.service unit for any session in {sessions}"
            machine.succeed(
                f"systemctl --user --machine=test@.host show pi-chat-{picked}.service "
                "--property=ProtectHome | grep -q '^ProtectHome=tmpfs'"
            )

        with subtest("memory extension stores facts and recalls them in a new session"):
            # End-to-end: real sediment binary + real embedding model
            # (pre-baked under $HF_HOME from sedimentPkg.modelCache,
            # no network), real cross-session vector store, real RPC
            # plumbing through the plugin. The mock LLM emits the
            # extractor fact line when it sees the trigger phrase and
            # surfaces the recalled body when the system prompt
            # carries a <recalled_memories> block — so a regression
            # in either hook (agent_end → store, before_agent_start →
            # recall + inject) fails this subtest loudly.
            machine.copy_from_host("${testPiMemory}", "/tmp/test-pi-memory.py")
            code, mem_out = machine.execute(
                sudo_env + "python3 /tmp/test-pi-memory.py "
                "${noctaliaBin} ${target} 2>&1"
            )
            if code != 0:
                # `sudo -u test …` strips sessionVariables, so SEDIMENT_DB
                # and HF_HOME default to sediment's own ~/.sediment/data
                # (empty) and trigger a HF download the sandbox is not on
                # the hook for. Splice both straight from the same Nix
                # values the pi-chat module writes into /etc/distro/pi-chat.json
                # so diagnostics hit the live agent DB, and pass --scope all
                # so globally-scoped writes from the agent actually show up.
                sed_env = (
                    "SEDIMENT_DB=/home/test/.local/state/distro/pi/sediment/data "
                    "HF_HOME=${
                      inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.sediment.modelCache
                    } "
                )
                _, sed_list = machine.execute(
                    sudo_env + sed_env + "sediment list --scope all --json 2>&1 || true"
                )
                machine.log("== sediment list --scope all ==\n" + sed_list)
                _, sed_stats = machine.execute(
                    sudo_env + sed_env + "sediment stats 2>&1 || true"
                )
                machine.log("== sediment stats ==\n" + sed_stats)
                _, mem_units = machine.execute(
                    sudo_env
                    + "journalctl --user -b --no-pager -u 'pi-chat-*.service' "
                    "2>&1 | tail -120"
                )
                machine.log("== pi-chat journal (memory) ==\n" + mem_units)
                # Pi's extension stderr surfaces through the noctalia
                # QML log, not the systemd journal. Tail every active
                # instance's log so failures inside the memory hooks
                # (extract, store, recall) are visible.
                _, noc_log = machine.execute(
                    "for f in /run/user/${uid}/quickshell/by-id/*/log.log; do "
                    "  echo === $f ===; tail -400 \"$f\" 2>&1; "
                    "done"
                )
                machine.log("== noctalia log (memory) ==\n" + noc_log)
                _, db_tree = machine.execute(
                    "ls -laR /home/test/.local/state/distro/pi/sediment "
                    "2>&1 || true"
                )
                machine.log("== sediment db tree ==\n" + db_tree)
                raise Exception(
                    "memory e2e failed (exit={}):\n{}".format(code, mem_out)
                )

        with subtest("noctalia persists notifications under the pi state tree"):
            # Fires the same DBus path the chat plugin's notifications skill
            # relies on. notify-send → org.freedesktop.Notifications →
            # noctalia's NotificationService → history.json. If the env
            # redirect to ~/.local/state/distro/pi/notifications/ is not
            # actually honored by noctalia, this file never appears.
            sentinel = "vm-seeded-notification"
            machine.succeed(
                sudo_env + f"notify-send --urgency=normal pi-test {sentinel!r}"
            )
            notif_path = (
                "/home/test/.local/state/distro/pi/notifications/history.json"
            )
            machine.wait_until_succeeds(f"test -s {notif_path}", timeout=30)
            machine.wait_until_succeeds(
                f"grep -q {sentinel!r} {notif_path}", timeout=15
            )
            # And the CLI must surface it back. Mirrors what pi runs in
            # its sandboxed scope (DISTRO_NOTIFICATIONS_FILE = redirect).
            out = machine.succeed(
                sudo_env
                + f"DISTRO_NOTIFICATIONS_FILE={notif_path} notifications list"
            )
            assert sentinel in out, (
                f"notifications list did not surface {sentinel!r}:\n{out}"
            )
      '';
  };
in
if useOpenrouter then
  # __impure grants the build sandbox network access so the VM's
  # user-mode NIC can actually reach api.openrouter.ai. Without this
  # the second NIC is wired up but trapped behind the sandbox.
  baseTest.overrideTestDerivation (_prev: {
    __impure = true;
  })
else
  baseTest
