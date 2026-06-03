# Behavioural contract for the spaces shortcut-wrapper library
# (lib/spaces-command.nix).
#
# A wrapper whose command fails must surface that failure two ways: a
# "failed to <label>" desktop notification (notify-send, urgency
# critical) and the underlying exit status, unchanged. A wrapper whose
# command succeeds must stay silent.
#
# notify-send is stubbed first on PATH so the failure toast is
# observable. No system eval, no compositor. ~2-5s.
{ pkgs, ... }:
let
  mkCommand = import ../../lib/spaces-command.nix pkgs;

  failing = mkCommand {
    name = "spaces-probe-failing";
    label = "do the thing";
    text = "( exit 5 )";
  };
  ok = mkCommand {
    name = "spaces-probe-ok";
    label = "do the thing";
    text = "true";
  };

  # Records every notify-send invocation's argv (one line) so the
  # assertions can match the title/body/urgency.
  stubNotify = pkgs.writeShellScriptBin "notify-send" ''
    printf '%s\n' "$*" >> "$NOTIFY_WITNESS"
  '';
in
pkgs.runCommand "spaces-command-wrapper-test" { } ''
  set -u
  export NOTIFY_WITNESS="$PWD/notify.log"
  : > "$NOTIFY_WITNESS"
  # The wrapper resolves notify-send by bare name; put the stub first.
  export PATH=${stubNotify}/bin:$PATH

  # Failure path: the wrapper must propagate the exit status (5) and
  # fire the critical "failed to <label>" toast.
  set +e
  ${failing}/bin/spaces-probe-failing
  status=$?
  set -e
  [ "$status" -eq 5 ] \
    || { echo "FAIL: wrapper changed exit status (got $status, want 5)" >&2; exit 1; }
  grep -q 'failed to do the thing' "$NOTIFY_WITNESS" \
    || { echo "FAIL: failure notification missing" >&2; cat "$NOTIFY_WITNESS" >&2; exit 1; }
  grep -q -- '--urgency=critical' "$NOTIFY_WITNESS" \
    || { echo "FAIL: failure toast not marked critical" >&2; cat "$NOTIFY_WITNESS" >&2; exit 1; }

  # Success path: no notification at all.
  : > "$NOTIFY_WITNESS"
  ${ok}/bin/spaces-probe-ok
  [ ! -s "$NOTIFY_WITNESS" ] \
    || { echo "FAIL: notification fired on success" >&2; cat "$NOTIFY_WITNESS" >&2; exit 1; }

  touch $out
''
