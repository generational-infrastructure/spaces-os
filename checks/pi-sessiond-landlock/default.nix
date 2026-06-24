# Cheap kernel check for the Landlock launcher (design §13 Phase 1 / §12).
#
# Landlock is access control enforced by the running kernel, so this needs a real
# boot (a runNixOSTest, not a bare runCommand). It probes the MECHANISM in
# isolation — pi-landlock-exec applied around small probe binaries under a known
# landlockconfig policy — so the confinement thesis stands before any
# pi-sessiond wiring exists.
#
# Asserts, in one boot, that the emitted domain:
#   - allows writing the granted workspace and executing from /nix/store;
#   - denies reading a file outside the allowlist (EACCES);
#   - allows connect() to the granted proxy port, denies any other (ABI 4);
#   - denies signalling a process outside the domain, allows its own children
#     (ABI 6 scoping — the load-bearing replacement for distinct-uid isolation);
#   - reports full enforcement at Landlock ABI >= 4.
{ pkgs, inputs, ... }:
let
  landlock = inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.pi-landlock-exec;
  py = "${pkgs.python3}/bin/python3";

  # A deny-by-default domain shaped like a real session policy (design §5.5):
  # rw workspace, ro+x /nix/store, connect-only to one TCP port, IPC scoping.
  policy = pkgs.writeText "landlock-probe.json" (
    builtins.toJSON {
      abi = 6;
      ruleset = [
        {
          scoped = [
            "signal"
            "abstract_unix_socket"
          ];
        }
      ];
      pathBeneath = [
        {
          allowedAccess = [ "abi.read_execute" ];
          parent = [ "/nix/store" ];
        }
        {
          allowedAccess = [ "abi.read_write" ];
          parent = [ "/root/ws" ];
        }
      ];
      netPort = [
        {
          allowedAccess = [ "connect_tcp" ];
          port = [ 7000 ];
        }
      ];
    }
  );

  # Probe binaries that run *inside* the domain (so they live in /nix/store, the
  # one executable grant). Each prints a single token the driver asserts on.
  listener = pkgs.writeScript "ll-listener.py" ''
    #!${py}
    import socket, sys, time
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", int(sys.argv[1])))
    s.listen(8)
    time.sleep(3600)
  '';
  netprobe = pkgs.writeScript "ll-netprobe.py" ''
    #!${py}
    import socket, sys
    s = socket.socket(); s.settimeout(3)
    try:
        s.connect(("127.0.0.1", int(sys.argv[1]))); print("NETOK"); s.close()
    except PermissionError:
        print("NETEPERM")
    except ConnectionRefusedError:
        print("NETREFUSED")
    except Exception as e:
        print("NETERR:%r" % (e,))
  '';
  sigprobe = pkgs.writeScript "ll-sigprobe.py" ''
    #!${py}
    import os, sys
    try:
        os.kill(int(sys.argv[1]), 0); print("SIGLEAK")
    except PermissionError:
        print("SIGEPERM")
    except ProcessLookupError:
        print("SIGNOPROC")
  '';
  childsig = pkgs.writeScript "ll-childsig.py" ''
    #!${py}
    import os, signal, time
    pid = os.fork()
    if pid == 0:
        time.sleep(10); os._exit(0)
    time.sleep(0.3)
    try:
        os.kill(pid, 0); print("CHILDOK")
    finally:
        try:
            os.kill(pid, signal.SIGKILL)
        except Exception:
            pass
  '';

  ll = "${landlock}/bin/pi-landlock-exec --json ${policy} --";
in
pkgs.testers.runNixOSTest {
  name = "pi-sessiond-landlock";
  meta.platforms = [ "x86_64-linux" ];
  nodes.machine = { };
  testScript = ''
    import re

    machine.wait_for_unit("multi-user.target")

    # Granted workspace must exist before restrict_self (a missing parent is a
    # skipped rule, not a grant); the secret is deliberately outside any grant.
    machine.succeed("mkdir -p /root/ws")
    machine.succeed("echo TOPSECRET > /root/secret.txt")

    # --- enforcement banner + ABI level -----------------------------------
    status, out = machine.execute("${ll} ${pkgs.coreutils}/bin/true 2>&1")
    print("launcher banner:\n" + out)
    assert status == 0, f"launcher failed to exec the target: {out!r}"
    assert "domain fully enforced" in out, f"domain not fully enforced: {out!r}"
    m = re.search(r"ABI (\d+)", out)
    assert m and int(m.group(1)) >= 4, f"kernel Landlock ABI < 4: {out!r}"

    # --- filesystem allowlist ---------------------------------------------
    # Executing any probe at all proves /nix/store read+execute is granted.
    machine.succeed("${ll} ${pkgs.bash}/bin/bash -c 'echo hi > /root/ws/probe'")
    machine.succeed("test \"$(cat /root/ws/probe)\" = hi")

    status, out = machine.execute("${ll} ${pkgs.coreutils}/bin/cat /root/secret.txt 2>&1")
    assert status != 0 and "Permission denied" in out, \
        f"FS breach: read a file outside the allowlist: {out!r}"

    # --- network: connect to granted port only (ABI 4) --------------------
    machine.succeed("systemd-run --unit=ll-listen --collect ${listener} 7000")
    # Confirm the listener is up by connecting from *outside* the domain.
    machine.wait_until_succeeds("${netprobe} 7000 | grep -q NETOK")

    out = machine.succeed("${ll} ${netprobe} 7000")
    assert "NETOK" in out, f"granted port connect blocked: {out!r}"
    out = machine.succeed("${ll} ${netprobe} 8000")
    assert "NETEPERM" in out, f"net breach: connect to a non-granted port: {out!r}"

    # --- IPC scoping: deny signalling outside the domain (ABI 6) -----------
    machine.succeed("systemd-run --unit=ll-victim --collect ${pkgs.coreutils}/bin/sleep 3600")
    machine.wait_until_succeeds("systemctl show --value -p MainPID ll-victim | grep -qE '^[0-9]+$'")
    vpid = machine.succeed("systemctl show --value -p MainPID ll-victim").strip()
    machine.succeed(f"kill -0 {vpid}")  # signallable from outside the domain

    out = machine.succeed(f"${ll} ${sigprobe} {vpid}")
    assert "SIGEPERM" in out, f"signal-scope breach: signalled an outside pid: {out!r}"
    out = machine.succeed("${ll} ${childsig}")
    assert "CHILDOK" in out, f"same-domain signal wrongly blocked: {out!r}"

    print("PASS: Landlock domain enforces fs/net/scope deny-by-default")
  '';
}
