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
  notifying = mkCommand {
    name = "spaces-probe-notifying";
    label = "do the thing";
    text = ''spaces_notify "did the thing"'';
  };
  notifyingTimed = mkCommand {
    name = "spaces-probe-notifying-timed";
    label = "do the thing";
    text = ''spaces_notify "timed thing" 2000'';
  };
  notifyingFail = mkCommand {
    name = "spaces-probe-notifying-fail";
    label = "do the thing";
    # Fails before it can reach the spaces_notify call.
    text = ''
      ( exit 7 )
      spaces_notify "did the thing"
    '';
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

  # A wrapper whose body calls `spaces_notify` posts an info toast: the
  # message fires, and it is neither critical nor a failure toast.
  : > "$NOTIFY_WITNESS"
  ${notifying}/bin/spaces-probe-notifying
  grep -q 'did the thing' "$NOTIFY_WITNESS" \
    || { echo "FAIL: success notification missing" >&2; cat "$NOTIFY_WITNESS" >&2; exit 1; }
  if grep -q -- '--urgency=critical' "$NOTIFY_WITNESS"; then
    echo "FAIL: success notification marked critical" >&2; cat "$NOTIFY_WITNESS" >&2; exit 1
  fi
  if grep -q 'failed to' "$NOTIFY_WITNESS"; then
    echo "FAIL: success path fired a failure toast" >&2; cat "$NOTIFY_WITNESS" >&2; exit 1
  fi
  # A bare spaces_notify (no duration arg) must not set an expire time.
  if grep -q -- '--expire-time' "$NOTIFY_WITNESS"; then
    echo "FAIL: bare spaces_notify must not set an expire time" >&2; cat "$NOTIFY_WITNESS" >&2; exit 1
  fi

  # A second argument to spaces_notify sets --expire-time (milliseconds).
  : > "$NOTIFY_WITNESS"
  ${notifyingTimed}/bin/spaces-probe-notifying-timed
  grep -q -- '--expire-time=2000' "$NOTIFY_WITNESS" \
    || { echo "FAIL: spaces_notify duration arg must set --expire-time=2000" >&2; cat "$NOTIFY_WITNESS" >&2; exit 1; }

  # When that same command fails, only the failure toast fires — the
  # info message must not appear.
  : > "$NOTIFY_WITNESS"
  set +e
  ${notifyingFail}/bin/spaces-probe-notifying-fail
  status=$?
  set -e
  [ "$status" -eq 7 ] \
    || { echo "FAIL: notifying wrapper changed exit status (got $status, want 7)" >&2; exit 1; }
  grep -q 'failed to do the thing' "$NOTIFY_WITNESS" \
    || { echo "FAIL: failure toast missing on failing notify wrapper" >&2; cat "$NOTIFY_WITNESS" >&2; exit 1; }
  if grep -q 'did the thing' "$NOTIFY_WITNESS"; then
    echo "FAIL: info toast fired despite command failure" >&2; cat "$NOTIFY_WITNESS" >&2; exit 1
  fi

  touch $out
''
