# NixOS VM check for the apps module + app-coordinator daemon.
#
# Headless verification of:
#   - `services.spaces.apps.<name>` evaluates and produces the
#     expected build artefacts (per-app launcher on PATH; manifest
#     JSON at /etc/spaces/app-coordinator/manifest.json)
#   - the user-systemd `spaces-app-coordinator.service` activates
#     under `default.target` and listens on
#     $XDG_RUNTIME_DIR/spaces-app-coordinator.sock with mode 0600
#   - the wire protocol `list / spawn / running / kill` does what
#     it claims (happy path + sad path)
#   - per-app `allowedArgs` rejects non-matching runtime args
#     before fork, with the failing arg index reported
#   - sandboxed apps observe the expected $HOME redirect and
#     ProtectHome=tmpfs effects inside their unit
#
# Out of scope (covered elsewhere or punted):
#   - Wayland security-context: needs niri + a rendering compositor;
#     test-machine.nix is the right home for that integration once
#     extended.
#   - wm.foreign-toplevel-management enforcement: same — needs niri.
#
# x86_64-linux only: pkgs.testers.runNixOSTest needs a builder with
# `kvm + nixos-test`. Other systems get a trivial stub so
# `nix flake check` stays green on aarch64 CI.
{ pkgs, inputs, ... }:

if pkgs.stdenv.hostPlatform.system != "x86_64-linux" then
  pkgs.runCommand "apps-coordinator-x86_64-only" { } "mkdir -p $out"
else
  pkgs.testers.runNixOSTest {
    name = "apps-coordinator";
    node.specialArgs = { inherit inputs; };
    nodes.machine =
      { lib, pkgs, ... }:
      {
        imports = [
          inputs.self.nixosModules.apps
        ];

        # A regular user for the launcher / coordinator to run as.
        # uid=1000 matches the path conventions ($XDG_RUNTIME_DIR =
        # /run/user/1000) the test script expects.
        users.users.alice = {
          isNormalUser = true;
          uid = 1000;
          password = "";
        };

        # The coordinator is a user systemd service; it needs the user
        # manager to be running. Without an interactive login (no
        # graphical session in this test) `loginctl enable-linger`
        # is the simplest way to start user@1000.service at boot.
        systemd.tmpfiles.rules = [
          # Mark alice as a lingering user — equivalent to
          # `loginctl enable-linger alice` baked at activation.
          "f /var/lib/systemd/linger/alice 0644 root root - -"

          # Pre-populate a canary in the host-side secret store. The
          # baseline mode (`0640 root:users`) is what the live spaces
          # uses for things like the OpenRouter API key — alice is in
          # `users`, so without InaccessiblePaths masking she'd
          # happily read this from inside any sandbox. The probe app
          # below tries to cat it; the regression assertion fails
          # loudly if the content reaches the journal.
          "d /run/spaces-secrets 0750 root users -"
          "f /run/spaces-secrets/canary 0640 root users - spaces-test-canary-DO-NOT-LEAK"
        ];

        # Socat is how the test script speaks the line-JSON protocol;
        # also useful as a smoke-test of the socket itself.
        environment.systemPackages = [ pkgs.socat ];

        services.spaces.apps = {
          # No permissions, no allowedArgs — the default-deny baseline.
          # Used to confirm spawn-with-no-args works and any arg is
          # refused.
          locked = {
            package = pkgs.coreutils;
            exec = "${pkgs.coreutils}/bin/true";
          };

          # Same as `probe-sleeper` (prints a marker + sleeps) but
          # `network` is explicitly DENIED. Used to verify the
          # "denies-last" claim: even after `spaces-apps grant
          # network-denied network`, the launcher must still emit
          # PrivateNetwork=true. The static deny is the load-bearing
          # security property — a compromised operator-CLI cannot
          # bypass it through the runtime-grant file.
          network-denied = {
            package = pkgs.bash;
            exec = "${pkgs.bash}/bin/sh";
            args = [
              "-c"
              ''
                echo NETWORK_DENIED_MARKER 1>&2
                ${pkgs.coreutils}/bin/sleep 30
              ''
            ];
            permissions.denied = [ "network" ];
          };

          # Has `wm.spawn-named-tasks` so the coordinator activates
          # (browser's manifest entry is what triggers
          # `anyAppNeedsCoordinator`). allowedArgs lets URLs and one
          # specific flag through. The two `wayland.*` permissions
          # also exercise the wayland-permissions.txt generator —
          # not enforced yet (Niri patch is still a draft) but the
          # at-rest file should list both grants for this app-id.
          browser = {
            package = pkgs.coreutils;
            exec = "${pkgs.coreutils}/bin/true";
            permissions.granted = [
              "wm.spawn-named-tasks"
              "wayland.virtual-keyboard"
              "wayland.screen-capture"
            ];
            allowedArgs = [
              "^https?://.+$"
              "^--profile=[a-zA-Z0-9-]+$"
            ];
          };

          # Prints its $HOME + visible /home entries so the test script
          # can assert the sandbox is actually applied. We can't use
          # the `wayland` permission here (no compositor in the VM);
          # other permissions are exercised by inspecting the resulting
          # service unit.
          #
          # Avoids external commands (no `ls` etc.) so the probe runs
          # without coreutils on PATH. The shell glob `/home/*`
          # expands inside the sandbox: if ProtectHome=tmpfs +
          # BindPaths landed correctly, only `/home/app` exists, so
          # the glob expands to that single path.
          probe = {
            package = pkgs.bash;
            exec = "${pkgs.bash}/bin/sh";
            args = [
              "-c"
              # Iterate the /home/* glob: `*` is its own token here so
              # pathname expansion actually runs. (`echo PREFIX=/home/*`
              # would treat the entire `PREFIX=/home/*` as one pattern
              # and find no matches.) Each visible entry prints one
              # SANDBOX_HOME_ENTRY=... line.
              #
              # Also dumps DBUS_SESSION_BUS_ADDRESS so the dbus subtest
              # can confirm an app without `dbusSession.*` config does
              # NOT receive any bus address at all.
              ''
                echo SANDBOX_HOME=$HOME 1>&2
                for entry in /home/*; do
                  echo SANDBOX_HOME_ENTRY=$entry 1>&2
                done
                echo SANDBOX_DBUS=''${DBUS_SESSION_BUS_ADDRESS:-NONE} 1>&2
                # ─ Hardening probes ───────────────────────────────
                # Only assert the properties that actually engage in
                # `systemd-run --user` mode. ProcSubset=pid and
                # ProtectProc=invisible are accepted but silently no-op
                # in user mode (need CAP_SYS_ADMIN to remount /proc).
                #
                # UMask=0077 → bash's `umask` builtin prints 0077.
                echo HARDEN_UMASK=$(umask) 1>&2
                # CapabilityBoundingSet= drops every cap → CapBnd is
                # all-zero bitmask in /proc/self/status. /proc is
                # readable by the unit's own PID (ProcSubset is a
                # no-op here) so the file is reachable. Use absolute
                # paths — coreutils isn't on $PATH in the sandbox.
                while IFS= read -r line; do
                  case "$line" in
                    CapBnd:*) echo "HARDEN_$line" 1>&2 ;;
                  esac
                done < /proc/self/status
                # ─ Secret-store leak probe ─────────────────────────
                # Read attempt against /run/spaces-secrets/canary
                # (which the host tmpfiles rule above pre-populated
                # with "spaces-test-canary-DO-NOT-LEAK"). If the
                # InaccessiblePaths= baseline is in effect the read
                # fails; the canary content must NOT reach the
                # journal under any branch of the if/else.
                #
                # `[ -r ... ]` is a bash builtin so no PATH needed.
                # `read < file` likewise; we capture exactly one line.
                if [ -r /run/spaces-secrets/canary ]; then
                  read -r leaked < /run/spaces-secrets/canary
                  echo "SECRET_PROBE=read=$leaked" 1>&2
                else
                  echo "SECRET_PROBE=blocked" 1>&2
                fi
              ''
            ];
          };

          # Same shape as `probe` but with a non-empty dbusSession
          # filter. The sandboxed `DBUS_SESSION_BUS_ADDRESS` should
          # point at the xdg-dbus-proxy socket in /tmp, not the raw
          # user bus path the launcher binds in for the proxy itself.
          probe-dbus = {
            package = pkgs.bash;
            exec = "${pkgs.bash}/bin/sh";
            args = [
              "-c"
              ''
                echo SANDBOX_DBUS=''${DBUS_SESSION_BUS_ADDRESS:-NONE} 1>&2
              ''
            ];
            dbusSession.talk = [ "org.freedesktop.DBus" ];
          };

          # Exercises spawnableBy. Only one specific app-id is allowed;
          # the host shell — which is what `socat` from the test
          # harness resolves to — must be rejected.
          agent-only = {
            package = pkgs.coreutils;
            exec = "${pkgs.coreutils}/bin/true";
            spawnableBy = [ "spaces.app.agent" ];
          };

          # Exercises `credentials = { name = host-path; }`. The
          # canary file is the same one the secret-leak probe uses,
          # so we get to verify *both* halves of the model in a
          # single fixture: the path is masked at /run/spaces-secrets/
          # but reachable via $CREDENTIALS_DIRECTORY/cred when
          # declared explicitly.
          probe-creds = {
            package = pkgs.bash;
            exec = "${pkgs.bash}/bin/sh";
            args = [
              "-c"
              ''
                # systemd places loaded credentials at $CREDENTIALS_DIRECTORY/<name>.
                if [ -r "''${CREDENTIALS_DIRECTORY:-/missing}/cred" ]; then
                  read -r value < "''${CREDENTIALS_DIRECTORY}/cred"
                  echo "CRED_PROBE=read=$value" 1>&2
                else
                  echo "CRED_PROBE=missing" 1>&2
                fi
                # Sanity: the raw host path must still be masked even
                # though we loaded the same content via LoadCredential.
                if [ -r /run/spaces-secrets/canary ]; then
                  read -r leaked < /run/spaces-secrets/canary
                  echo "CRED_PROBE_RAW=read=$leaked" 1>&2
                else
                  echo "CRED_PROBE_RAW=blocked" 1>&2
                fi
              ''
            ];
            credentials.cred = "/run/spaces-secrets/canary";
          };

          # Round-trip dbus test: this probe talks to org.freedesktop.
          # systemd1 (which the user dbus session bus always exposes
          # in a NixOS unit) and prints whether the call succeeded.
          # `dbusSession.talk` whitelists exactly that service, so
          # the proxy must let the call through.
          probe-dbus-allowed = {
            package = pkgs.bash;
            exec = "${pkgs.bash}/bin/sh";
            args = [
              "-c"
              ''
                if ${pkgs.dbus}/bin/dbus-send --session --print-reply \
                     --dest=org.freedesktop.systemd1 \
                     /org/freedesktop/systemd1 \
                     org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; then
                  echo DBUS_PING_ALLOWED=ok 1>&2
                else
                  echo DBUS_PING_ALLOWED=denied 1>&2
                fi
              ''
            ];
            dbusSession.talk = [ "org.freedesktop.systemd1" ];
          };

          # Long-ish-lived probe used by the `spaces-apps logs`
          # subtest: prints a tagged line then sleeps so the unit
          # is still discoverable via `running` when the test
          # queries it. `--collect` reaps the unit after exit;
          # journalctl still surfaces the entries by unit name.
          probe-sleeper = {
            package = pkgs.bash;
            exec = "${pkgs.bash}/bin/sh";
            args = [
              "-c"
              ''
                echo LOGS_PROBE_MARKER 1>&2
                ${pkgs.coreutils}/bin/sleep 30
              ''
            ];
          };

          # Mirror probe with the *wrong* whitelist: only the bus
          # daemon itself is allowed, NOT systemd1. The same Ping
          # call must be denied by the proxy.
          probe-dbus-denied = {
            package = pkgs.bash;
            exec = "${pkgs.bash}/bin/sh";
            args = [
              "-c"
              ''
                if ${pkgs.dbus}/bin/dbus-send --session --print-reply \
                     --dest=org.freedesktop.systemd1 \
                     /org/freedesktop/systemd1 \
                     org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; then
                  echo DBUS_PING_DENIED=ok 1>&2
                else
                  echo DBUS_PING_DENIED=denied 1>&2
                fi
              ''
            ];
            dbusSession.talk = [ "org.freedesktop.DBus" ];
          };
        };

        virtualisation = {
          memorySize = 1024;
          cores = 2;
          writableStore = true;
        };
      };

    testScript = ''
      machine.wait_for_unit("multi-user.target")

      with subtest("alice user manager comes up under linger"):
          machine.wait_until_succeeds(
              "systemctl is-active user@1000.service",
              timeout=30,
          )

      with subtest("apps module rendered the manifest"):
          manifest = machine.succeed("cat /etc/spaces/app-coordinator/manifest.json")
          for name in ("locked", "browser", "probe"):
              assert f'"{name}"' in manifest, f"{name} missing from manifest: {manifest!r}"
          assert '"allowedArgs"' in manifest, manifest

      with subtest("launchers exist on system PATH"):
          for name in ("locked", "browser", "probe"):
              machine.succeed(f"test -x /run/current-system/sw/bin/app-run-{name}")

      with subtest("coordinator activates (browser holds wm.spawn-named-tasks)"):
          machine.wait_until_succeeds(
              "systemctl --user --machine=alice@.host is-active spaces-app-coordinator.service",
              timeout=30,
          )

      with subtest("coordinator socket exists, mode 0600"):
          machine.wait_until_succeeds(
              "test -S /run/user/1000/spaces-app-coordinator.sock",
              timeout=10,
          )
          mode = machine.succeed(
              "stat -c %a /run/user/1000/spaces-app-coordinator.sock"
          ).strip()
          assert mode == "600", f"expected mode 0600 on socket, got {mode}"

      def req(json):
          # Quote-safe JSON over a single-shot socat connection, as alice.
          cmd = (
              f"printf '%s\\n' '{json}' | "
              "sudo -u alice socat - UNIX-CONNECT:/run/user/1000/spaces-app-coordinator.sock"
          )
          return machine.succeed(cmd).strip()

      with subtest("list returns every manifest app"):
          out = req('{"op":"list"}')
          for name in ("locked", "browser", "probe"):
              assert f'"{name}"' in out, f"{name} missing from list reply: {out!r}"

      with subtest("locked: no-args spawn accepted"):
          out = req('{"op":"spawn","app":"locked"}')
          assert '"op":"ok"' in out, out

      with subtest("locked: any arg rejected (default deny)"):
          out = req('{"op":"spawn","app":"locked","args":["whatever"]}')
          assert "does not match" in out, out
          assert '"op":"error"' in out, out

      with subtest("browser: URL passes the allow-list"):
          out = req('{"op":"spawn","app":"browser","args":["https://example.com"]}')
          assert '"op":"ok"' in out, out

      with subtest("browser: --profile flag passes the allow-list"):
          out = req('{"op":"spawn","app":"browser","args":["--profile=alice"]}')
          assert '"op":"ok"' in out, out

      with subtest("browser: javascript:URL rejected (URL pattern requires http(s))"):
          out = req('{"op":"spawn","app":"browser","args":["javascript:alert(1)"]}')
          assert "does not match" in out, out

      with subtest("browser: one-good-one-bad arg combo rejected, index reported"):
          out = req('{"op":"spawn","app":"browser","args":["https://x","--evil"]}')
          assert '"arg[1]"' in out or "arg[1]" in out, out

      with subtest("unknown app rejected"):
          out = req('{"op":"spawn","app":"ghost"}')
          assert "unknown app" in out, out

      with subtest("kill refuses non-app units"):
          out = req('{"op":"kill","unit":"dbus.socket"}')
          assert "refusing to kill non-app unit" in out, out

      with subtest("kill refuses unit without manifest entry"):
          out = req('{"op":"kill","unit":"app-evil-99.service"}')
          assert "unknown app in unit" in out, out

      with subtest("info: returns the manifest entry for a known app"):
          # `browser` has a non-trivial entry: wm.spawn-named-tasks
          # in granted, two allowedArgs patterns, no requested perms.
          # The reply must surface enough to reconstruct the full
          # entry without anyone having to read /nix/store launchers.
          out = req('{"op":"info","app":"browser"}')
          assert '"op":"ok"' in out, out
          import json as _json
          parsed = _json.loads(out)
          info = parsed.get("info") or {}
          assert info.get("granted") == [
              "wm.spawn-named-tasks",
              "wayland.virtual-keyboard",
              "wayland.screen-capture",
          ], info
          assert info.get("requested", []) == [], info
          # allowedArgs is the two-pattern URL + profile list:
          assert "^https?://.+$" in info.get("allowedArgs", []), info
          # And the launcher path points at our /run/current-system PATH:
          assert info.get("launcherPath", "").endswith(
              "/bin/app-run-browser"
          ), info

      with subtest("info: rejects unknown app"):
          out = req('{"op":"info","app":"ghost"}')
          assert "unknown app" in out, out

      with subtest("audit log: each op emits a structured AUDIT line"):
          # The coordinator writes one JSON line per dispatched op to
          # its stderr, prefixed `AUDIT `. The line lands in the
          # coordinator service's journal — queryable per-unit.
          # Trigger fresh activity:
          req('{"op":"info","app":"browser"}')
          req('{"op":"spawn","app":"locked"}')
          # And a deliberate failure for the error path:
          req('{"op":"info","app":"ghost"}')

          audit_journal = machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 "
              "journalctl --user --since '30 sec ago' "
              "-u spaces-app-coordinator.service -o cat | grep '^AUDIT '"
          )
          # Each AUDIT line should be valid JSON with the fields we
          # require for a forensic timeline: ts, caller, op, result.
          import json as _json
          audit_lines = [
              line[len("AUDIT "):]
              for line in audit_journal.splitlines()
              if line.startswith("AUDIT ")
          ]
          assert audit_lines, f"no AUDIT lines in journal:\n{audit_journal}"
          ops_seen = set()
          for line in audit_lines:
              entry = _json.loads(line)
              for required in ("ts", "caller", "op", "result"):
                  assert required in entry, f"AUDIT missing {required}: {entry!r}"
              ops_seen.add(entry["op"])
          # The three ops we just dispatched must all show up:
          assert {"info", "spawn"}.issubset(ops_seen), (
              f"expected info+spawn in audit ops; got {ops_seen!r}"
          )
          # Confirm the error case landed too — the bogus info on
          # 'ghost' must produce a result=error AUDIT line.
          error_lines = [
              _json.loads(line) for line in audit_lines
              if '"result":"error"' in line
          ]
          assert error_lines, "no error-result AUDIT line found"

      with subtest("spaces-apps CLI: list / info wrap the JSON protocol"):
          # Lands on PATH via apps.nix → environment.systemPackages.
          # The CLI resolves the socket via XDG_RUNTIME_DIR.
          machine.succeed("test -x /run/current-system/sw/bin/spaces-apps")
          list_out = machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps list"
          ).strip().splitlines()
          for expected in ("browser", "locked", "agent-only", "probe", "probe-dbus-allowed"):
              assert expected in list_out, (
                  f"spaces-apps list missing {expected!r}; got: {list_out!r}"
              )

          # info on a known app prints labelled human-readable text.
          info_out = machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps info browser"
          )
          assert "wm.spawn-named-tasks" in info_out, info_out
          assert "^https?://.+$" in info_out, info_out
          assert "launcher:" in info_out, info_out

          # --json gives the raw coordinator reply for piping into jq.
          json_out = machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps --json info browser"
          )
          import json as _json
          parsed = _json.loads(json_out)
          assert parsed["op"] == "ok", parsed
          assert parsed["info"]["granted"] == [
              "wm.spawn-named-tasks",
              "wayland.virtual-keyboard",
              "wayland.screen-capture",
          ], parsed

          # info on an unknown app exits non-zero with the coordinator's error.
          rc, info_err = machine.execute(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps info ghost 2>&1"
          )
          assert rc != 0, f"expected non-zero exit; rc={rc}, out={info_err}"
          assert "unknown app" in info_err, info_err

          # spawn forwards the request and reports the assigned unit.
          spawn_out = machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps spawn locked"
          )
          assert "ok:" in spawn_out and "app-locked-" in spawn_out, spawn_out

      with subtest("spaces-apps CLI: logs surfaces a unit's journal output"):
          # Spawn the sleeper, find its unit via `running`, then
          # ask the CLI for that unit's logs and confirm the probe's
          # tagged stderr is in there.
          out = req('{"op":"spawn","app":"probe-sleeper"}')
          assert '"op":"ok"' in out, out
          # Wait for the probe to actually print before querying.
          machine.wait_until_succeeds(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 "
              "journalctl --user --since '10 sec ago' -o cat | grep -q LOGS_PROBE_MARKER",
              timeout=15,
          )
          # `running` should now include the sleeper unit; pick it.
          import json as _json
          running = _json.loads(
              machine.succeed(
                  "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps --json running"
              )
          )
          sleeper_unit = next(
              (r["unit"] for r in running.get("running", []) if r["app"] == "probe-sleeper"),
              None,
          )
          assert sleeper_unit, f"probe-sleeper not in running list: {running!r}"

          # Now run the actual logs subcommand and check it brought
          # the marker through.
          logs_out = machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps logs " + sleeper_unit
          )
          assert "LOGS_PROBE_MARKER" in logs_out, (
              f"spaces-apps logs did not surface the probe's stderr; got:\n{logs_out}"
          )

          # Defensive: refusing non-app units is the whole point of
          # the prefix/suffix check; verify it.
          rc, refuse_err = machine.execute(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps logs dbus.socket 2>&1"
          )
          assert rc != 0, f"expected non-zero exit; got rc={rc}, out={refuse_err}"
          assert "does not look like an app unit" in refuse_err, refuse_err

          # Clean up the sleeper so it doesn't hold the slot for the
          # rest of the test run.
          machine.succeed(
              f"sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps kill {sleeper_unit}"
          )

      with subtest("permissions.json: catalogue published with descriptions"):
          # /etc/spaces/permissions.json is the at-rest copy of the
          # closed permission catalogue (name → description). It's
          # what `spaces-apps permissions` and `spaces-apps info
          # --describe` consume.
          import json as _json
          cat = _json.loads(machine.succeed("cat /etc/spaces/permissions.json"))
          # Spot-check several known entries:
          for name in (
              "network",
              "wayland",
              "wm.spawn-named-tasks",
              "wayland.virtual-keyboard",
              "wayland.screen-capture",
          ):
              assert name in cat, f"permission {name!r} missing from catalogue"
              assert isinstance(cat[name], str) and cat[name], (
                  f"permission {name!r} has empty or non-string description: {cat[name]!r}"
              )
          # The removed placeholder should NOT be in the catalogue.
          assert "wm.foreign-toplevel-management" not in cat, (
              "stale wm.foreign-toplevel-management entry still in catalogue"
          )

      with subtest("spaces-apps permissions: prints the catalogue"):
          out = machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps permissions"
          )
          # The output is `name  description` lines. Spot-check.
          assert "network " in out and "PrivateNetwork=true" in out, out
          assert "wayland.virtual-keyboard " in out, out
          # --json round-trips the catalogue file unchanged.
          json_out = machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps --json permissions"
          )
          cat2 = _json.loads(json_out)
          assert cat2 == cat, (
              f"permissions --json output diverges from /etc/spaces/permissions.json\n"
              f"got: {cat2!r}\nexpected: {cat!r}"
          )

      with subtest("spaces-apps info --describe: surfaces permission descriptions"):
          # Go's flag package stops parsing at the first non-flag
          # argument, so the flag must come before the subcommand.
          out = machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps --describe info browser"
          )
          # Each granted permission should be on its own line with its description.
          assert "wm.spawn-named-tasks" in out, out
          assert "Coordinator may launch" in out, out
          assert "virtual-keyboard" in out, out
          assert "synthetic keystrokes" in out, out

      with subtest("spaces-apps grants: grant / revoke round-trip + validation"):
          # Start from empty grants:
          grants_dir = "/home/alice/.local/state/spaces/grants"
          machine.succeed(f"sudo -u alice mkdir -p {grants_dir}")
          machine.succeed(f"sudo -u alice rm -f {grants_dir}/*.json || true")

          # An empty grants file (no file) returns the empty list.
          out = machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps grants browser"
          )
          assert "(no runtime grants)" in out, out

          # grant a valid permission, then check it shows up.
          machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
              "spaces-apps grant browser network"
          )
          out = machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps grants browser"
          )
          assert "network" in out, out

          # The file should exist at the expected path with mode 0600.
          file_path = f"{grants_dir}/spaces.app.browser.json"
          mode = machine.succeed(f"stat -c %a {file_path}").strip()
          assert mode == "600", f"expected mode 0600, got {mode}"

          import json as _json
          parsed = _json.loads(machine.succeed(f"cat {file_path}"))
          assert parsed["version"] == 1, parsed
          assert parsed["granted"] == ["network"], parsed

          # grant the same permission again — should be idempotent.
          machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
              "spaces-apps grant browser network"
          )
          parsed = _json.loads(machine.succeed(f"cat {file_path}"))
          assert parsed["granted"] == ["network"], (
              f"grant should be idempotent; got {parsed!r}"
          )

          # grant a second permission, expect sorted order.
          machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
              "spaces-apps grant browser audio.playback"
          )
          parsed = _json.loads(machine.succeed(f"cat {file_path}"))
          assert parsed["granted"] == ["audio.playback", "network"], parsed

          # revoke one, the other stays.
          machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
              "spaces-apps revoke browser network"
          )
          parsed = _json.loads(machine.succeed(f"cat {file_path}"))
          assert parsed["granted"] == ["audio.playback"], parsed

          # grant an unknown permission — should fail with a clear error
          # and NOT modify the file.
          rc, err_out = machine.execute(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
              "spaces-apps grant browser bogus.permission 2>&1"
          )
          assert rc != 0, f"expected non-zero exit; got rc={rc}, out={err_out}"
          assert "unknown permission" in err_out, err_out
          parsed = _json.loads(machine.succeed(f"cat {file_path}"))
          assert parsed["granted"] == ["audio.playback"], (
              f"failed grant should not modify file; got {parsed!r}"
          )

          # grant on an unknown app — should fail with the coordinator's
          # `unknown app` error and not create a file.
          rc, err_out = machine.execute(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
              "spaces-apps grant ghost network 2>&1"
          )
          assert rc != 0, err_out
          assert "unknown app" in err_out, err_out

      with subtest("spaces-apps: bash completion script is shipped and usable"):
          # The completion file lives at the standard XDG location
          # so bash-completion auto-discovers it.
          machine.succeed(
              "test -r "
              "$(readlink -f /run/current-system/sw/share/bash-completion/completions/spaces-apps "
              "|| echo /run/current-system/sw/share/bash-completion/completions/spaces-apps)"
          )
          # Source the completion and ask for subcommand-name completions
          # at an empty position. The output should include every
          # documented subcommand.
          # We test by simulating Tab completion: set COMP_LINE/COMP_POINT
          # then invoke the _spaces_apps function.
          completion = machine.succeed(
              "bash -c '"
              "source /run/current-system/sw/share/bash-completion/completions/spaces-apps; "
              "COMP_WORDS=(spaces-apps \"\"); "
              "COMP_CWORD=1; "
              "_spaces_apps; "
              "printf \"%s\\n\" \"''${COMPREPLY[@]}\"'"
          )
          for sub in ("list", "info", "running", "spawn", "kill", "logs", "audit", "verify", "permissions", "grants", "grant", "revoke"):
              assert sub in completion.splitlines(), (
                  f"subcommand {sub!r} missing from completion output:\n{completion}"
              )

      with subtest("spaces-apps: grant/revoke completion is context-aware"):
          # First grant one permission so we have a known state to
          # diff against.
          machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
              "spaces-apps grant locked network"
          )

          # revoke locked <Tab> — should suggest ONLY `network`
          # (the only granted permission). Run completion as alice
          # so it can talk to the coordinator on her socket.
          revoke_comp = machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 bash -c '"
              "source /run/current-system/sw/share/bash-completion/completions/spaces-apps; "
              "COMP_WORDS=(spaces-apps revoke locked \"\"); "
              "COMP_CWORD=3; "
              "_spaces_apps; "
              "printf \"%s\\n\" \"''${COMPREPLY[@]}\"'"
          ).strip().splitlines()
          assert revoke_comp == ["network"], (
              f"revoke completion should suggest ONLY currently-granted "
              f"permissions; got: {revoke_comp!r}"
          )

          # grant locked <Tab> — should suggest every permission
          # EXCEPT `network` (already granted).
          grant_comp = machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 bash -c '"
              "source /run/current-system/sw/share/bash-completion/completions/spaces-apps; "
              "COMP_WORDS=(spaces-apps grant locked \"\"); "
              "COMP_CWORD=3; "
              "_spaces_apps; "
              "printf \"%s\\n\" \"''${COMPREPLY[@]}\"'"
          ).strip().splitlines()
          assert "network" not in grant_comp, (
              f"grant completion should hide already-granted `network`; "
              f"got: {grant_comp!r}"
          )
          # Other permissions should still appear.
          assert "wayland" in grant_comp, (
              f"grant completion should still suggest un-granted perms; got: {grant_comp!r}"
          )

          # Clean up.
          machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
              "spaces-apps revoke locked network"
          )

      with subtest("runtime grant engages: launcher honors $HOME/.local/state/spaces/grants"):
          # `locked` has no static grants. By default its sandbox
          # gets PrivateNetwork=true (since `network` isn't in
          # effective). After we grant `network` at runtime via the
          # CLI, the launcher must read the grants file and DROP the
          # PrivateNetwork=true property from the spawned unit's
          # systemd config.
          grants_dir = "/home/alice/.local/state/spaces/grants"
          locked_grants = f"{grants_dir}/spaces.app.locked.json"

          # Start clean.
          machine.succeed(f"sudo -u alice rm -f {locked_grants}")

          # First spawn — no runtime grant. The resulting unit's
          # PrivateNetwork property should be `yes`.
          import time as _time
          machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
              "systemd-run --user --no-block --collect --unit=runtime-grant-baseline-$$ "
              "--property=PrivateTmp=true "
              "true"
          )
          # That above call was just a smoke test of systemd-run access.
          # Now actually use the launcher via the coordinator:
          out = req('{"op":"spawn","app":"probe-sleeper"}')
          assert '"op":"ok"' in out, out

          # Find the unit name from `running`.
          import json as _json
          _time.sleep(0.3)
          running = _json.loads(
              machine.succeed(
                  "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps --json running"
              )
          )
          baseline_unit = next(
              (r["unit"] for r in running.get("running", []) if r["app"] == "probe-sleeper"),
              None,
          )
          assert baseline_unit, f"probe-sleeper not running: {running!r}"
          baseline_pn = machine.succeed(
              f"sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 "
              f"systemctl --user show -p PrivateNetwork {baseline_unit}"
          ).strip()
          assert baseline_pn == "PrivateNetwork=yes", (
              f"baseline expected PrivateNetwork=yes, got {baseline_pn!r}"
          )
          # Clean up.
          machine.succeed(
              f"sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps kill {baseline_unit}"
          )

          # Runtime-grant network to probe-sleeper, then spawn again.
          machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
              "spaces-apps grant probe-sleeper network"
          )

          out = req('{"op":"spawn","app":"probe-sleeper"}')
          assert '"op":"ok"' in out, out
          _time.sleep(0.3)
          running = _json.loads(
              machine.succeed(
                  "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps --json running"
              )
          )
          granted_unit = next(
              (r["unit"] for r in running.get("running", []) if r["app"] == "probe-sleeper"),
              None,
          )
          assert granted_unit, f"second probe-sleeper not running: {running!r}"
          granted_pn = machine.succeed(
              f"sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 "
              f"systemctl --user show -p PrivateNetwork {granted_unit}"
          ).strip()
          assert granted_pn == "PrivateNetwork=no", (
              f"with runtime grant `network`, PrivateNetwork should be `no`; "
              f"got {granted_pn!r} — runtime grants are NOT engaging"
          )

          # Confirm the launcher's audit JSON (emitted to the
          # coordinator's stderr → journal, NOT the unit's journal)
          # includes `network` in the effective set.
          coord_journal = machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 "
              "journalctl --user --since '15 sec ago' "
              "-u spaces-app-coordinator.service -o cat"
          )
          assert '"effective":"network"' in coord_journal, (
              f"audit line missing or doesn't show runtime grant:\n{coord_journal}"
          )

          # Clean up.
          machine.succeed(
              f"sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps kill {granted_unit}"
          )
          machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
              "spaces-apps revoke probe-sleeper network"
          )

      with subtest("denies-last: static deny blocks runtime grant"):
          # `network-denied` has `permissions.denied = ["network"]`.
          # Runtime-granting `network` via the CLI MUST NOT enable
          # network access — the launcher applies denies after
          # unioning runtime grants. Without this, the operator
          # could pretend to deny something while a (potentially
          # compromised) grant file silently re-enables it.
          import time as _time
          machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
              "spaces-apps grant network-denied network"
          )

          out = req('{"op":"spawn","app":"network-denied"}')
          assert '"op":"ok"' in out, out
          _time.sleep(0.3)
          import json as _json
          running = _json.loads(
              machine.succeed(
                  "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps --json running"
              )
          )
          denied_unit = next(
              (r["unit"] for r in running.get("running", []) if r["app"] == "network-denied"),
              None,
          )
          assert denied_unit, f"network-denied not running: {running!r}"

          pn = machine.succeed(
              f"sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 "
              f"systemctl --user show -p PrivateNetwork {denied_unit}"
          ).strip()
          assert pn == "PrivateNetwork=yes", (
              f"static deny was bypassed by runtime grant. "
              f"PrivateNetwork={pn!r} (expected `yes`)"
          )

          # And the audit JSON's effective field must NOT contain
          # `network` — confirms the resolution order is right at
          # the launcher level, not just at the property-emission level.
          coord_journal = machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 "
              "journalctl --user --since '10 sec ago' "
              "-u spaces-app-coordinator.service -o cat"
          )
          # Find the most recent network-denied audit line.
          matching = [
              line for line in coord_journal.splitlines()
              if "network-denied" in line and "app-run" in line
          ]
          assert matching, f"no network-denied audit line:\n{coord_journal}"
          last_line = matching[-1]
          # The effective field is comma-joined; `network` must NOT
          # be in there even though we runtime-granted it.
          assert '"effective":"network"' not in last_line, (
              f"effective set leaked the runtime grant past the deny: {last_line!r}"
          )

          # Clean up.
          machine.succeed(
              f"sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps kill {denied_unit}"
          )
          machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
              "spaces-apps revoke network-denied network"
          )

      with subtest("wayland-permissions.txt: generated with the expected lines"):
          # The browser app declares two wayland.* permissions
          # (`virtual-keyboard` + `screen-capture`); the module
          # writes one "<appId> <permission>" line per entry to
          # /etc/spaces/wayland-permissions.txt, which the gating-patched
          # niri (applied via overlay in modules/nixos/niri.nix) reads at
          # startup. Assert the file is generated with the right contents.
          content = machine.succeed("cat /etc/spaces/wayland-permissions.txt")
          assert "spaces.app.browser wayland.virtual-keyboard" in content, content
          assert "spaces.app.browser wayland.screen-capture" in content, content
          # And nothing for an app that has no wayland.* grants:
          for line in content.splitlines():
              line = line.strip()
              if line.startswith("#") or not line:
                  continue
              app_id, _, _ = line.partition(" ")
              assert app_id != "spaces.app.locked", (
                  f"locked has no wayland.* perms but is in the file: {line!r}"
              )

      with subtest("spaces-apps CLI: verify all-checks-pass on a healthy machine"):
          verify_out = machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps verify"
          )
          # Every line should be a check; no failures expected on
          # the freshly-built test machine.
          assert "verify OK" in verify_out, verify_out
          # Spot-check coverage: the four expected check categories.
          for label in (
              "coordinator socket",
              "coordinator service",
              "manifest file",
              "launcher: browser",
              "launcher: probe",
          ):
              assert label in verify_out, f"verify missing label {label!r}; out:\n{verify_out}"
          # And that all checks reported their OK marker (no crosses).
          assert "✗" not in verify_out, (
              f"verify found a failed check on a clean machine:\n{verify_out}"
          )

      with subtest("spaces-apps CLI: verify reports failure when coordinator is down"):
          # Stop the coordinator and re-run verify; expect non-zero
          # exit and a failure row naming the dead service.
          machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 "
              "systemctl --user stop spaces-app-coordinator.service"
          )
          rc, broken_out = machine.execute(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps verify 2>&1"
          )
          assert rc != 0, f"verify should fail when coordinator is down; rc={rc}"
          assert "coordinator" in broken_out, broken_out
          assert "✗" in broken_out or "FAIL" in broken_out, broken_out
          # Bring it back so subsequent subtests still work.
          machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 "
              "systemctl --user start spaces-app-coordinator.service"
          )
          machine.wait_until_succeeds(
              "test -S /run/user/1000/spaces-app-coordinator.sock",
              timeout=10,
          )

      with subtest("spaces-apps CLI: cleanup finds stale grant files"):
          # Plant a grant file for an app-id NOT in the manifest.
          # `cleanup` (dry-run) should list it; `cleanup --apply`
          # should remove it. Valid grant files (for apps that DO
          # exist in the manifest) must be untouched.
          grants_dir = "/home/alice/.local/state/spaces/grants"
          machine.succeed(f"sudo -u alice mkdir -p {grants_dir}")

          # Plant a valid grant — for `browser`, which exists.
          machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
              "spaces-apps grant browser network"
          )

          # Plant a stale grant file directly.
          stale_path = f"{grants_dir}/spaces.app.no-such-app.json"
          machine.succeed(
              f"sudo -u alice sh -c 'echo \\\"{{\\\\\"version\\\\\":1,\\\\\"granted\\\\\":[]}}\\\" > {stale_path}'"
          )
          machine.succeed(f"test -r {stale_path}")

          # Dry-run cleanup — must list stale, must NOT remove.
          dry_out = machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
              "spaces-apps cleanup"
          )
          assert "spaces.app.no-such-app.json" in dry_out, dry_out
          assert "would remove" in dry_out, dry_out
          assert "spaces.app.browser.json" not in dry_out, (
              f"cleanup dry-run flagged the valid browser grant: {dry_out}"
          )
          # File still present after dry-run.
          machine.succeed(f"test -r {stale_path}")

          # --apply mode actually removes it. Flag must precede
          # the subcommand (Go's flag package convention).
          apply_out = machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
              "spaces-apps --apply cleanup"
          )
          assert "removing" in apply_out, apply_out
          # Stale file gone, valid file preserved.
          rc, _ = machine.execute(f"test -r {stale_path}")
          assert rc != 0, "stale grant file still present after --apply"
          machine.succeed(f"test -r {grants_dir}/spaces.app.browser.json")

          # Run again — now there's nothing stale.
          clean_out = machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
              "spaces-apps cleanup"
          )
          assert "no stale" in clean_out, clean_out

          # Tidy up the residual `network` grant on browser so it
          # doesn't pollute later subtests.
          machine.succeed(
              "sudo -u alice HOME=/home/alice XDG_RUNTIME_DIR=/run/user/1000 "
              "spaces-apps revoke browser network"
          )

      with subtest("spaces-apps CLI: spawns surfaces launcher app-run events"):
          # The launcher emits a JSON `app-run` event to stderr at
          # every launch. `spaces-apps spawns` scans the user
          # journal for those events and shows the effective
          # permission set that actually engaged. Trigger a spawn
          # then verify it shows up.
          out = req('{"op":"spawn","app":"locked"}')
          assert '"op":"ok"' in out, out
          spawns_out = machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps spawns -n 20"
          )
          # Human-readable format: <appId>  <name>  effective: <list>
          assert "spaces.app.locked" in spawns_out, spawns_out
          assert "effective:" in spawns_out, spawns_out

          # --json passes each event line through as JSON.
          spawns_json = machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps --json spawns -n 10"
          ).strip().splitlines()
          assert spawns_json, "spawns --json returned nothing"
          import json as _json
          for line in spawns_json:
              entry = _json.loads(line)
              assert entry.get("event") == "app-run", entry
              assert "appId" in entry, entry
              assert "effective" in entry, entry

      with subtest("spaces-apps CLI: audit shows AUDIT entries"):
          # The audit subcommand shells out to journalctl and filters
          # for AUDIT lines. After all the activity above there must
          # be plenty to show.
          audit_out = machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps audit -n 100"
          )
          # Human-readable lines: TIMESTAMP CALLER op[/err] app — error
          # Just verify we see something resembling the format and
          # that the ops we've fired show up.
          assert "spawn" in audit_out, audit_out
          assert "info" in audit_out, audit_out
          assert "host" in audit_out, audit_out

          # --json passes through the raw JSON one-line-per-entry.
          audit_json = machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 spaces-apps --json audit -n 5"
          ).strip().splitlines()
          import json as _json
          assert len(audit_json) > 0, "audit --json returned nothing"
          for line in audit_json:
              entry = _json.loads(line)
              for required in ("ts", "caller", "op", "result"):
                  assert required in entry, f"audit --json missing {required}: {entry!r}"

      with subtest("spawnableBy default ['*'] accepts host caller"):
          # `locked` doesn't override spawnableBy, so the lib default
          # `["*"]` applies — every caller including the host shell
          # (which is what socat-from-the-harness resolves to via
          # SO_PEERCRED) must be accepted.
          out = req('{"op":"spawn","app":"locked"}')
          assert '"op":"ok"' in out, out

      with subtest("spawnableBy restricts to a specific app-id, host rejected"):
          out = req('{"op":"spawn","app":"agent-only"}')
          assert '"op":"error"' in out, out
          assert "spawnableBy" in out, out
          assert "host" in out, (
              f"reply should name the rejected caller; got: {out!r}"
          )

      def alice_journal(since="15 sec ago"):
          return machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 "
              f"journalctl --user --since '{since}' -o cat"
          )

      with subtest("probe sandbox: $HOME is /home/app, /home masked"):
          out = req('{"op":"spawn","app":"probe"}')
          assert '"op":"ok"' in out, out
          # Wait for the probe unit's stderr to land in alice's user
          # journal. Running journalctl as alice avoids the systemd
          # machined `--machine=user@.host` non-root restriction we
          # hit when querying from the harness as root.
          machine.wait_until_succeeds(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 "
              "journalctl --user --since '15 sec ago' -o cat | "
              "grep -q 'SANDBOX_HOME=/home/app'",
              timeout=10,
          )
          # ProtectHome=tmpfs replaces /home with a tmpfs; the BindPaths
          # mount then re-adds /home/app. So iterating /home/* inside
          # the sandbox should yield exactly one entry: /home/app.
          journal = alice_journal()
          entries = [
              line for line in journal.splitlines()
              if line.startswith("SANDBOX_HOME_ENTRY=")
          ]
          assert entries == ["SANDBOX_HOME_ENTRY=/home/app"], (
              f"expected exactly /home/app inside sandbox; got: {entries!r}"
          )

      with subtest("credentials: LoadCredential exposes the host path inside the sandbox"):
          # probe-creds declares `credentials.cred = "/run/spaces-secrets/canary"`.
          # systemd reads the canary under PID 1 (which sees the
          # unmasked filesystem), stages it at
          # $CREDENTIALS_DIRECTORY/cred, mode 0400. The probe should
          # read back the exact canary content there — *while*
          # confirming the raw path is still inaccessible.
          out = req('{"op":"spawn","app":"probe-creds"}')
          assert '"op":"ok"' in out, out
          machine.wait_until_succeeds(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 "
              "journalctl --user --since '15 sec ago' -o cat | "
              "grep -q '^CRED_PROBE='",
              timeout=10,
          )
          journal = alice_journal()
          cred_lines = [
              line for line in journal.splitlines()
              if line.startswith("CRED_PROBE=") or line.startswith("CRED_PROBE_RAW=")
          ]
          assert (
              "CRED_PROBE=read=spaces-test-canary-DO-NOT-LEAK" in cred_lines
          ), (
              f"LoadCredential did not surface the secret at "
              f"$CREDENTIALS_DIRECTORY/cred. cred_lines:\n{cred_lines}"
          )
          assert "CRED_PROBE_RAW=blocked" in cred_lines, (
              f"raw /run/spaces-secrets/canary path became reachable "
              f"because we declared a credential. The two masks must "
              f"stay independent. cred_lines:\n{cred_lines}"
          )

      with subtest("secret-store leak: /run/spaces-secrets/canary is unreachable"):
          # The host tmpfiles rule wrote "spaces-test-canary-DO-NOT-LEAK"
          # at /run/spaces-secrets/canary, mode 0640 root:users.
          # alice is in `users`, so without the InaccessiblePaths=
          # baseline she'd happily read it from inside the sandbox.
          #
          # NOTE: we deliberately do NOT do a blanket
          # `"spaces-test-canary-DO-NOT-LEAK" not in journal` check —
          # the credentials subtest above *legitimately* surfaces
          # that exact string via LoadCredential, which is the
          # intended escape hatch. We instead check the specific
          # probe's marker: a `SECRET_PROBE=read=…` line means the
          # *raw filesystem path* was reachable.
          journal = alice_journal()
          probe_lines = [
              line for line in journal.splitlines()
              if line.startswith("SECRET_PROBE=")
          ]
          assert probe_lines, f"probe never reported SECRET_PROBE; journal:\n{journal}"
          leaks = [line for line in probe_lines if line.startswith("SECRET_PROBE=read=")]
          assert not leaks, (
              f"SECRET LEAK — sandboxed probe read /run/spaces-secrets/canary "
              f"directly via the filesystem. InaccessiblePaths= is missing or "
              f"ineffective. leaked: {leaks}"
          )
          assert "SECRET_PROBE=blocked" in probe_lines, (
              f"probe never reported a blocked read; last: {probe_lines[-1]!r}"
          )

      with subtest("hardening: UMask + CapabilityBoundingSet engaged"):
          journal = alice_journal()
          assert "HARDEN_UMASK=0077" in journal, (
              f"sandbox UMask not 0077; journal:\n{journal}"
          )
          # CapBnd is a hex bitmask; all-zero means the bounding set
          # is empty. Anything else means some capability slipped
          # through. systemd writes lowercase hex; bash `read` of
          # /proc/self/status's `CapBnd:` line emits e.g.
          # `HARDEN_CapBnd:	0000000000000000`.
          import re
          m = re.search(r"HARDEN_CapBnd:\s+([0-9a-f]+)", journal)
          assert m, f"no HARDEN_CapBnd: line in journal:\n{journal}"
          assert int(m.group(1), 16) == 0, (
              f"CapabilityBoundingSet not empty: {m.group(1)!r}"
          )

      with subtest("probe sandbox: no dbusSession → no bus address in env"):
          # `probe` has no dbusSession.* — the sandboxed app must see
          # DBUS_SESSION_BUS_ADDRESS unset (printed as the literal
          # NONE by the `${"VAR:-NONE"}` fallback in the probe script).
          journal = alice_journal()
          lines = [
              line for line in journal.splitlines()
              if line.startswith("SANDBOX_DBUS=")
          ]
          assert lines, f"probe never printed SANDBOX_DBUS line; journal:\n{journal}"
          assert lines[-1] == "SANDBOX_DBUS=NONE", (
              f"probe with empty dbusSession leaked DBUS env: {lines[-1]!r}"
          )

      with subtest("dbus bridge: round-trip to whitelisted name succeeds"):
          # Whitelist is `["org.freedesktop.systemd1"]`; the proxy
          # must let dbus-send's Ping reach the user systemd manager
          # and the reply must come back through the same socket.
          out = req('{"op":"spawn","app":"probe-dbus-allowed"}')
          assert '"op":"ok"' in out, out
          machine.wait_until_succeeds(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 "
              "journalctl --user --since '15 sec ago' -o cat | "
              "grep -q '^DBUS_PING_ALLOWED='",
              timeout=10,
          )
          journal = alice_journal()
          assert "DBUS_PING_ALLOWED=ok" in journal, (
              f"whitelisted dbus call did not round-trip; journal:\n{journal}"
          )

      with subtest("dbus bridge: --log emits audit markers for the probe's call"):
          # The bridge invokes xdg-dbus-proxy with --log; per-message
          # audit lines land on the unit's stderr and from there into
          # journald. The actual format is terse — lines like
          # `*SKIPPED*`, `*HIDDEN* (ping)`, `*REWRITTEN*` without
          # rich destination/method info. Limited forensic value but
          # proves the flag is wired correctly and the proxy is
          # processing traffic. (Richer audit would require either
          # an upstream xdg-dbus-proxy patch or replacing it with
          # something like dbus-monitor + a filter — deferred.)
          log_journal = machine.succeed(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 "
              "journalctl --user --since '60 sec ago' "
              "-u 'app-probe-dbus-allowed-*.service' -o cat"
          )
          audit_markers = [
              "*SKIPPED*",
              "*HIDDEN*",
              "*REWRITTEN*",
              "*INVALID*",
              "*FILTERED*",
          ]
          hits = [m for m in audit_markers if m in log_journal]
          assert hits, (
              f"dbus bridge --log did not emit any of the known audit "
              f"markers {audit_markers!r}. journal:\n{log_journal}"
          )

      with subtest("dbus bridge: round-trip to non-whitelisted name denied"):
          # Same Ping but the whitelist is `["org.freedesktop.DBus"]`
          # — the bus daemon itself, NOT systemd1. The proxy must
          # refuse, dbus-send must exit non-zero, the probe must
          # report `denied`.
          out = req('{"op":"spawn","app":"probe-dbus-denied"}')
          assert '"op":"ok"' in out, out
          machine.wait_until_succeeds(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 "
              "journalctl --user --since '15 sec ago' -o cat | "
              "grep -q '^DBUS_PING_DENIED='",
              timeout=10,
          )
          journal = alice_journal()
          assert "DBUS_PING_DENIED=denied" in journal, (
              f"proxy let through a call it should have blocked; journal:\n{journal}"
          )

      with subtest("probe-dbus sandbox: dbusSession → proxy socket in env"):
          out = req('{"op":"spawn","app":"probe-dbus"}')
          assert '"op":"ok"' in out, out
          machine.wait_until_succeeds(
              "sudo -u alice XDG_RUNTIME_DIR=/run/user/1000 "
              "journalctl --user --since '15 sec ago' -o cat | "
              "grep -q 'SANDBOX_DBUS=unix:path=/tmp/dbus-proxy-'",
              timeout=10,
          )
          # Reaffirm: the bus address points at the in-sandbox proxy,
          # *not* the raw `unix:path=$XDG_RUNTIME_DIR/bus`.
          journal = alice_journal()
          dbus_lines = [
              line for line in journal.splitlines()
              if line.startswith("SANDBOX_DBUS=") and "dbus-proxy" in line
          ]
          assert dbus_lines, (
              f"probe-dbus never printed a proxy-pointing SANDBOX_DBUS "
              f"line; journal:\n{journal}"
          )
          assert "/run/user/1000/bus" not in dbus_lines[-1], (
              f"probe-dbus saw raw bus address instead of proxy: {dbus_lines[-1]!r}"
          )
    '';
  }
