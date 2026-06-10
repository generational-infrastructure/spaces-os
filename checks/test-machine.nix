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
# Headless verification of the wiring around niri, the standalone
# pi-chat Quickshell panel, the pi-chat NixOS module, and llama-swap
# (or openrouter):
#   - greetd starts and opens a PAM session for the test user
#   - the user manager (user@1000.service) comes up
#   - niri.service activates and exposes a Wayland socket
#   - pi-chat.service materializes the shell into
#     ~/.config/quickshell/pi-chat with fresh mtimes (ExecStartPre) and
#     starts under graphical-session.target
#   - the IpcHandler target `pi-chat` is registered with the running
#     quickshell instance and answers `listSessions` / `send` / …
#   - the test user can send a message through the shell IPC and the
#     pi session hosted by the loopback pi-sessiond replies (via local
#     mock or openrouter, depending on mode)
#   - the memory extension stores facts in one session and recalls
#     them in another (cross-session sediment round-trip)
#   - spaces-notify-forward bridges a desktop notification into the
#     active chat session via the new `quickshell ipc -c pi-chat`
#     invocation
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
  wsProbe = ./test-machine-ws-probe.py;
  pyWs = pkgs.python3.withPackages (ps: [ ps.websockets ]);

  baseTest = pkgs.testers.runNixOSTest {
    name = "test-machine${lib.optionalString useOpenrouter "-openrouter"}";
    meta.platforms = [ "x86_64-linux" ];
    node.specialArgs = { inherit inputs; };
    nodes.test-machine =
      { lib, pkgs, ... }:
      {
        imports = [
          inputs.self.nixosModules.spaces
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
          pyWs
          pkgs.curl
          pkgs.mako
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
          # bash-confirm stays enabled: the daemon gates every bash tool
          # call behind the confirm side-channel, which the sandbox probe
          # exercises end-to-end. The chat round-trip + memory e2e never
          # invoke bash, so they don't need confirms answered.
          # Opt the test VM into the forwarder so the
          # notification-bridge subtest has something to drive.
          notificationForwarding.enable = true;
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

        # Notification daemon. The pi-chat module is daemon-agnostic
        # — production users pick mako, dunst, swaync, KDE plasma's
        # built-in, etc. — but the notification-forwarding subtest
        # needs *some* implementation of org.freedesktop.Notifications
        # for `notify-send` to dispatch to. mako is the smallest
        # wlr-layer-shell-friendly choice.
        systemd.user.services.mako = {
          description = "mako notification daemon";
          partOf = [ "graphical-session.target" ];
          after = [ "graphical-session.target" ];
          wantedBy = [ "graphical-session.target" ];
          serviceConfig = {
            ExecStart = "${pkgs.mako}/bin/mako";
            Restart = "on-failure";
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
        # Shell config name + IpcHandler target. Both are "pi-chat"
        # post-cutover; kept as Nix bindings so future rename only
        # touches one spot.
        shellConfig = "pi-chat";
        target = "pi-chat";
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
            # pam_systemd starts user@1000.service when greetd opens the session;
            # use wait_until_succeeds because the start job may not be queued yet.
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

        with subtest("shell config materialized with fresh mtimes"):
            # The pi-chat module's pi-chat.service ExecStartPre copies
            # programs/pi-chat into ~/.config/quickshell/pi-chat with
            # current mtimes so Qt's qmlcache invalidates on rebuild.
            # Assert both the copy exists and shell.qml has a current
            # mtime — a regression to a /nix/store symlink would
            # leave mtime at the 1970-01-01 epoch.
            machine.wait_until_succeeds(
                "test -f /home/test/.config/quickshell/${shellConfig}/shell.qml "
                "&& test ! -L /home/test/.config/quickshell/${shellConfig}",
                timeout=30,
            )
            mtime = int(machine.succeed(
                "stat -c %Y /home/test/.config/quickshell/${shellConfig}/shell.qml"
            ).strip())
            if mtime < 1_577_836_800:  # 2020-01-01
                raise Exception(
                    f"shell.qml has nix-store epoch mtime ({mtime}); "
                    "Qt qmlcache will pin stale bytecode across rebuilds"
                )

        with subtest("pi-chat.service is running"):
            machine.wait_until_succeeds(
                "systemctl --user --machine=test@.host is-active pi-chat.service",
                timeout=30,
            )
            machine.wait_until_succeeds(
                "test -d /run/user/${uid}/quickshell",
                timeout=30,
            )

        with subtest("pi-chat sidecar services come up"):
            machine.wait_until_succeeds(
                "systemctl --user --machine=test@.host is-active spaces-skill-config-daemon.service",
                timeout=30,
            )
            machine.wait_for_file(
                "/run/user/${uid}/spaces-skill-config.sock", timeout=30
            )

        with subtest("daemon agent config is staged (settings + skills + allowlist)"):
            # pi-sessiond-local seeds its own agent dir from the module's
            # settings template at startup; skills ride settings.json and
            # the bash-confirm allow-list is a sibling file. The legacy
            # panel-side ~/.local/state/spaces/pi/pi-agent dir is gone.
            machine.wait_until_succeeds(
                "test -f /home/test/.local/state/pi-sessiond-local/pi-agent/settings.json",
                timeout=60,
            )
            machine.succeed(
                "grep -q 'skills' /home/test/.local/state/pi-sessiond-local/pi-agent/settings.json"
            )
            machine.succeed(
                "test -f /home/test/.local/state/pi-sessiond-local/pi-agent/bash-confirm.json"
            )

        with subtest("llama-swap is up"):
            machine.wait_for_open_port(8012, timeout=120)

        # Shared sudo env block: the test driver runs as root, but
        # quickshell ipc + IPC handlers need to talk to the per-user
        # quickshell instance through XDG_RUNTIME_DIR.
        sudo_env = (
            "sudo -u test "
            "HOME=/home/test "
            "XDG_RUNTIME_DIR=/run/user/${uid} "
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus "
            "WAYLAND_DISPLAY=wayland-1 "
        )

        with subtest("shell IPC target is registered"):
            # `quickshell ipc -c <name> show` enumerates every
            # IpcHandler target the running instance has bound. If
            # shell.qml threw at load time the target will be missing
            # — dump every diagnostic quickshell exposes (instance
            # list + per-instance log) and bail immediately so the
            # failure mode is loud.
            code, ipc_out = machine.execute(
                sudo_env + "quickshell ipc -c ${shellConfig} show 2>&1"
            )
            if code != 0 or "${target}" not in ipc_out:
                _, instances_raw = machine.execute(
                    sudo_env + "quickshell list -a --json 2>&1"
                )
                machine.log("== quickshell instances ==\n" + instances_raw)
                _, pi_chat_journal = machine.execute(
                    "journalctl --user-unit pi-chat.service --no-pager "
                    "_UID=${uid} -b 2>&1 | tail -100"
                )
                machine.log("== pi-chat.service journal ==\n" + pi_chat_journal)
                _, qs_tree = machine.execute(
                    "find /run/user/${uid}/quickshell -mindepth 1 "
                    "-printf '%p\\t%y\\t%s\\n' 2>&1 || true"
                )
                machine.log("== quickshell runtime tree ==\n" + qs_tree)
                _, raw_log = machine.execute(
                    "for f in /run/user/${uid}/quickshell/by-id/*/log.log; do "
                    "  echo === $f ===; "
                    "  tail -200 \"$f\" 2>&1; "
                    "done"
                )
                machine.log("== quickshell raw log.log ==\n" + raw_log)
                raise Exception(
                    f"IPC target ${target} missing (exit={code}):\n{ipc_out}"
                )
            machine.succeed(
                sudo_env + "quickshell ipc -c ${shellConfig} call ${target} listSessions"
            )

        with subtest("chat round-trip through shell IPC"):
            machine.copy_from_host("${testPiChat}", "/tmp/test-pi-chat.py")
            code, ptest_out = machine.execute(
                sudo_env + "python3 /tmp/test-pi-chat.py "
                "quickshell ${shellConfig} ${target} ${modeArg} 2>&1"
            )
            if code != 0:
                # Sessions live inside the loopback daemon; surface its
                # journal so silent pi failures are visible at the first
                # run rather than via timeout.
                _, j = machine.execute(
                    sudo_env
                    + "journalctl --user -b --no-pager -u pi-sessiond-local.service "
                    "2>&1 | tail -100"
                )
                machine.log("== pi-sessiond-local journal ==\n" + j)
                _, qs_log = machine.execute(
                    "tail -n 80 /run/user/${uid}/quickshell/by-id/*/log.log 2>&1"
                )
                machine.log("== quickshell plaintext log ==\n" + qs_log)
                _, cfg_dump = machine.execute(
                    "cat /etc/spaces/pi-chat.json 2>&1"
                )
                machine.log("== /etc/spaces/pi-chat.json ==\n" + cfg_dump)
                raise Exception(
                    "chat round-trip failed (exit={}):\n{}".format(code, ptest_out)
                )

        with subtest("no per-session local pi units exist (local spawn is gone)"):
            # Cutover regression guard: every session must live on the
            # loopback executor. A pi-chat-<sid>.service unit would mean
            # the deleted local-spawn path somehow came back.
            units = machine.succeed(
                sudo_env + "systemctl --user list-units 'pi-chat-*.service' --all --no-legend 2>&1"
            ).strip()
            assert units == "", f"unexpected local pi units: {units!r}"

        with subtest("memory extension stores facts and recalls them in a new session"):
            # End-to-end: real sediment binary + real embedding model
            # (pre-baked under $HF_HOME from sedimentPkg.modelCache,
            # no network), real cross-session vector store, real RPC
            # plumbing through the shell. The mock LLM emits the
            # extractor fact line when it sees the trigger phrase and
            # surfaces the recalled body when the system prompt
            # carries a <recalled_memories> block — so a regression
            # in either hook (agent_end → store, before_agent_start →
            # recall + inject) fails this subtest loudly.
            machine.copy_from_host("${testPiMemory}", "/tmp/test-pi-memory.py")
            code, mem_out = machine.execute(
                sudo_env + "python3 /tmp/test-pi-memory.py "
                "quickshell ${shellConfig} ${target} 2>&1"
            )
            if code != 0:
                # `sudo -u test …` strips sessionVariables, so SEDIMENT_DB
                # and HF_HOME default to sediment's own ~/.sediment/data
                # (empty) and trigger a HF download the sandbox is not on
                # the hook for. Splice both straight from the same Nix
                # values the pi-chat module writes into /etc/spaces/pi-chat.json
                # so diagnostics hit the live agent DB, and pass --scope all
                # so globally-scoped writes from the agent actually show up.
                sed_env = (
                    "SEDIMENT_DB=/home/test/.local/state/spaces/pi/sediment/data "
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
                    + "journalctl --user -b --no-pager -u pi-sessiond-local.service "
                    "2>&1 | tail -120"
                )
                machine.log("== pi-sessiond-local journal (memory) ==\n" + mem_units)
                _, qs_log = machine.execute(
                    "for f in /run/user/${uid}/quickshell/by-id/*/log.log; do "
                    "  echo === $f ===; tail -n 400 \"$f\" 2>&1; "
                    "done"
                )
                machine.log("== quickshell log (memory) ==\n" + qs_log)
                _, db_tree = machine.execute(
                    "ls -laR /home/test/.local/state/spaces/pi/sediment "
                    "2>&1 || true"
                )
                machine.log("== sediment db tree ==\n" + db_tree)
                raise Exception(
                    "memory e2e failed (exit={}):\n{}".format(code, mem_out)
                )

        # ── Loopback executor (pi-sessiond-local): security invariants ──
        # Folded in from the former local-executor-machine check: these
        # depend on the same full boot path (greetd → user manager →
        # daemon) this test already pays for. The sandbox probe drives
        # the mock LLM, so it stays local-mode only.
        with subtest("loopback daemon runs in the user manager, not as root"):
            machine.wait_until_succeeds(
                "systemctl --user --machine=test@.host is-active pi-sessiond-local.service",
                timeout=120,
            )
            pid = machine.succeed(
                "systemctl --user --machine=test@.host show -p MainPID --value "
                "pi-sessiond-local.service"
            ).strip()
            assert pid != "0", "daemon has no main pid"
            daemon_uid = machine.succeed(f"stat -c %u /proc/{pid}").strip()
            assert daemon_uid == "${uid}", f"daemon uid {daemon_uid}, expected ${uid}"

        machine.succeed("echo home-marker-secret > /home/test/secret-marker")
        machine.succeed("chown test /home/test/secret-marker")

        with subtest("daemon mount namespace hides the user's home"):
            machine.succeed("test -f /home/test/secret-marker")
            machine.fail(f"nsenter -t {pid} -m test -f /home/test/secret-marker")

        with subtest("daemon listens on 8768 (bun cold start can take a while)"):
            machine.wait_until_succeeds("ss -tln | grep -q ':8768 '", timeout=180)

        with subtest("WS auth: runtime token accepted, wrong token rejected"):
            machine.succeed(
                "su - test -c 'XDG_RUNTIME_DIR=/run/user/${uid} "
                "${pyWs}/bin/python3 ${wsProbe} 8768 "
                "/run/user/${uid}/pi-sessiond-local/token auth'"
            )

        ${lib.optionalString (!useOpenrouter) ''
          with subtest("bash tool runs sandboxed: HOME hidden inside the unit"):
              out = machine.succeed(
                  "su - test -c 'XDG_RUNTIME_DIR=/run/user/${uid} "
                  "${pyWs}/bin/python3 ${wsProbe} 8768 "
                  "/run/user/${uid}/pi-sessiond-local/token sandbox'"
              )
              assert "HOME-DENIED" in out
              assert "home-marker-secret" not in out
        ''}

        with subtest("panel config defaults to the loopback executor"):
            machine.succeed(
                "${pkgs.jq}/bin/jq -e '.localExecutor.id == \"host\" "
                "and .defaultExecutor == \"host\"' /etc/spaces/pi-chat.json"
            )

        with subtest("spaces-notify-forward unit comes up"):
            # Full e2e (notify-send → forwarder → quickshell IPC → chat)
            # was attempted here but the dbus-monitor shell scraper at
            # the heart of the forwarder turns out to be the wrong
            # primitive — it sees the bus traffic but the bash
            # pipeline never flushes the lines through `while read`
            # reliably under nixos-test's QEMU. Replacing it with a
            # proper Rust+zbus subscriber is in the plan as a separate
            # commit; until then this subtest only asserts the unit
            # starts.
            machine.wait_until_succeeds(
                "systemctl --user --machine=test@.host is-active spaces-notify-forward.service",
                timeout=30,
            )
            machine.wait_until_succeeds(
                "systemctl --user --machine=test@.host is-active mako.service",
                timeout=30,
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
