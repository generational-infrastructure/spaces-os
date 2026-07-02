# shellcheck shell=bash
# reap_swtpm <swtpm-state-dir> — reap an orphaned swtpm before (re)launch.
#
# nixpkgs' qemu-vm runner starts `swtpm socket --tpmstate dir=<D> … --daemon`
# and stops it via a bash coproc that fires `swtpm_ioctl --stop` when QEMU
# exits. A hard kill of the whole process group (pueue kill, closed terminal,
# host crash) takes the coproc down WITH QEMU, so the swtpm daemon survives,
# holding a POSIX write lock on <D>/.lock. The next launch's swtpm then dies
# with "SWTPM_NVRAM_Lock_Dir: Could not lock access to lockfile" and the
# runner exits 1 before QEMU ever starts.
#
# Returns 0 when the dir is clean or an orphan was reaped (safe to launch);
# returns 1 when a live qemu-system still references that swtpm's control
# socket — killing it would yank the TPM out from under a running VM, so the
# caller must abort instead. Sourced by the test-vm and agent-vm launchers
# (this file is the single source of truth). Needs pgrep (procps) and
# readlink/sleep (coreutils) on PATH.
reap_swtpm() {
  local dir pids qemu
  # The runner canonicalises NIX_SWTPM_DIR (readlink -f), so the daemon's
  # argv carries the resolved path; match against the same form. A missing
  # dir still resolves (only the final component may be absent) — and a
  # dir that never existed simply finds no processes.
  dir=$(readlink -f -- "$1" 2>/dev/null) || return 0

  # The runner's exact invocation shape; trailing space so dir=/x never
  # matches a daemon for dir=/x-other.
  pids=$(pgrep -f "swtpm socket --tpmstate dir=$dir " || true)
  [ -z "$pids" ] && return 0

  # Live VM? QEMU connects to the swtpm over <D>/socket.ctrl and keeps that
  # path in its argv (-chardev socket,id=chrtpm,path=…). No leading dash in
  # the pattern — pgrep would parse it as an option.
  qemu=$(pgrep -f "chardev socket,id=chrtpm,path=$dir/socket.ctrl" || true)
  if [ -n "$qemu" ]; then
    echo "reap-swtpm: a running QEMU (pid $qemu) is still attached to $dir — refusing to reap; stop that VM first" >&2
    return 1
  fi

  echo "reap-swtpm: killing orphaned swtpm (pid $pids) holding $dir" >&2
  # shellcheck disable=SC2086 # pids is a newline-separated PID list
  kill $pids 2>/dev/null || true
  for _ in $(seq 1 20); do
    # shellcheck disable=SC2086
    kill -0 $pids 2>/dev/null || return 0
    sleep 0.1
  done
  # shellcheck disable=SC2086
  kill -9 $pids 2>/dev/null || true
  return 0
}
