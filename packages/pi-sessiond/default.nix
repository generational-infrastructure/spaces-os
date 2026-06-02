{ pkgs, ... }:
# Red-phase placeholder for the remote-pi executor daemon.
#
# The real pi-sessiond is the TypeScript daemon from docs/remote-pi-design.md:
# a token-authenticated WebSocket listener that spawns one sandboxed
# `pi --mode rpc` subprocess per session, stamps + fans out pi's event stream,
# and serializes client commands into each subprocess's stdin.
#
# Until that lands (green), this placeholder only opens the configured TCP
# port and accepts-then-drops connections. That is deliberate: it lets the
# multi-VM check in checks/pi-remote-session/ exercise the whole two-node path
# (both VMs boot, the client reaches the server over the test network, the
# executor service is up and listening) and fail *precisely* at the
# WebSocket/session protocol — the behaviour green implements — instead of
# dying on "service down" or an undefined symbol.
pkgs.writeShellScriptBin "pi-sessiond" ''
  exec ${pkgs.python3}/bin/python3 ${./placeholder.py}
''
