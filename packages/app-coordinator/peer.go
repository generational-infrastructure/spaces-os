package main

import (
	"fmt"
	"net"
	"os"
	"strings"
	"syscall"
)

// hostCaller is the conventional app-id for any peer that isn't
// itself inside a managed app sandbox — terminal users, scripts the
// operator runs by hand, the niri keybind helpers, etc. Apps whose
// `spawnableBy` includes "host" accept this caller; apps that don't
// reject it.
const hostCaller = "host"

// callerAppID resolves the connecting peer to a spaces app-id, or
// `hostCaller` if the peer isn't running inside a managed app
// sandbox.
//
// Resolution: SO_PEERCRED on the Unix socket yields the peer's PID;
// /proc/<pid>/cgroup names the systemd unit. App-managed units have
// the form `app-<name>-<pid>.service` (assigned by the launcher),
// from which we recover the app-id `spaces.app.<name>`. Anything
// else — interactive sessions, unmanaged scripts, the launcher
// itself before it has execed into systemd-run — resolves to
// `host`.
//
// Fail-closed: any error in the resolution chain (cred not
// available, /proc/<pid>/cgroup unreadable, parse failure) falls
// back to `host`. That means a misbehaving caller can at worst
// claim host-equivalent privileges, not impersonate a specific app.
func callerAppID(conn net.Conn) string {
	uc, ok := conn.(*net.UnixConn)
	if !ok {
		return hostCaller
	}
	sc, err := uc.SyscallConn()
	if err != nil {
		return hostCaller
	}

	var cred *syscall.Ucred
	var sockErr error
	_ = sc.Control(func(fd uintptr) {
		cred, sockErr = syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
	})
	if sockErr != nil || cred == nil {
		return hostCaller
	}

	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/cgroup", cred.Pid))
	if err != nil {
		return hostCaller
	}

	return appIDFromCgroup(string(data))
}

// appIDFromCgroup walks the cgroup v2 hierarchy looking for an
// `app-<name>-<pid>.service` component and returns
// `spaces.app.<name>`. Returns `host` when none is found.
//
// Cgroup v2 format (a single `0::<path>` line):
//
//	0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-firefox-12345.service
//
// Older cgroup v1 hierarchies emit one line per controller; the
// same parsing rule works for any of them because we're just
// scanning for the `app-…` component.
func appIDFromCgroup(cgroupContents string) string {
	for _, line := range strings.Split(cgroupContents, "\n") {
		// cgroup v2: "0::<path>" (single line)
		// cgroup v1: "<id>:<controller>:<path>" (multiple lines)
		idx := strings.LastIndex(line, ":")
		if idx < 0 {
			continue
		}
		cgPath := line[idx+1:]
		for _, comp := range strings.Split(cgPath, "/") {
			if !strings.HasPrefix(comp, "app-") {
				continue
			}
			stem := strings.TrimSuffix(comp, ".service")
			stem = strings.TrimSuffix(stem, ".scope")
			stem = strings.TrimPrefix(stem, "app-")
			// Format is `<name>-<pid>` — drop the suffix.
			if dash := strings.LastIndex(stem, "-"); dash > 0 {
				return "spaces.app." + stem[:dash]
			}
		}
	}
	return hostCaller
}

// callerAllowed reports whether a caller with the given app-id may
// invoke a target whose manifest declares `spawnableBy`. An empty
// list rejects every caller. `"*"` matches any caller. Otherwise
// the caller's app-id must appear verbatim.
func callerAllowed(callerID string, spawnableBy []string) bool {
	for _, allowed := range spawnableBy {
		if allowed == "*" || allowed == callerID {
			return true
		}
	}
	return false
}
