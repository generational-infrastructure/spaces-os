/*
 * wayland-app-context — establish a Wayland security-context-v1 sandbox
 *                       and exec into the target program.
 *
 * Niri (and any wlroots/Smithay compositor) already gates the dangerous
 * Wayland protocols (wlr-screencopy, wlr-foreign-toplevel-management,
 * data-control, virtual-keyboard, etc.) on whether the client comes in
 * via security-context-v1. This helper is the bit that *creates* such
 * a context for a sandboxed app:
 *
 *   1. Connect to the compositor via the user's existing $WAYLAND_DISPLAY
 *   2. Bind wp_security_context_manager_v1 from the registry
 *   3. Bind a fresh Unix socket at $XDG_RUNTIME_DIR/wayland-app-<id>
 *   4. Create a pipe; pass (listener_fd, close_pipe_read) to the
 *      compositor via wp_security_context_manager_v1.create_listener
 *   5. Set sandbox-engine / app-id / instance-id, commit
 *   6. Roundtrip so commit lands on the server
 *   7. Disconnect Wayland (the compositor has its own dup'd fds)
 *   8. Clear FD_CLOEXEC on the close pipe's write end so it survives exec
 *   9. setenv WAYLAND_DISPLAY=<new socket path>
 *  10. execvp the target
 *
 * The compositor's view of "this connection is restricted" is keyed off
 * the listener fd, so every Wayland connection the target opens to the
 * new socket is tagged. When the target exits, the kernel closes the
 * inherited write end of the close pipe, the compositor sees EOF on the
 * read end, and tears the security context down.
 *
 * Usage:
 *   wayland-app-context --engine=ENGINE --app-id=ID --instance-id=ID \
 *                       -- /path/to/target [args...]
 *
 * On any failure to set up the security context the helper exits non-zero
 * WITHOUT execing the target — fail-closed: better to not launch than to
 * launch unsandboxed.
 */
/* pipe2 + getrandom are GNU/Linux extensions; opt-in to feature
 * macros before any libc header. */
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#include "security-context-v1-client-protocol.h"

struct registry_state {
	struct wp_security_context_manager_v1 *manager;
};

static void registry_global(void *data, struct wl_registry *registry,
                            uint32_t name, const char *interface, uint32_t version) {
	struct registry_state *state = data;
	if (strcmp(interface, wp_security_context_manager_v1_interface.name) == 0) {
		uint32_t bind_version = version < 1 ? version : 1;
		state->manager = wl_registry_bind(registry, name,
		                                  &wp_security_context_manager_v1_interface,
		                                  bind_version);
	}
}

static void registry_global_remove(void *data, struct wl_registry *registry,
                                   uint32_t name) {
	(void)data;
	(void)registry;
	(void)name;
}

static const struct wl_registry_listener registry_listener = {
	.global = registry_global,
	.global_remove = registry_global_remove,
};

/* Build a bound + listening AF_UNIX SOCK_STREAM at path. Returns the fd
 * on success; -1 on failure (errno set). */
static int bind_listener(const char *path) {
	int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if (fd < 0) return -1;

	struct sockaddr_un addr = { .sun_family = AF_UNIX };
	if (strlen(path) >= sizeof addr.sun_path) {
		errno = ENAMETOOLONG;
		goto fail;
	}
	memcpy(addr.sun_path, path, strlen(path) + 1);

	/* Stale socket from a prior helper run would make bind() EADDRINUSE.
	 * Helper-managed dir, helper-controlled path: safe to unlink. */
	(void)unlink(path);

	if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) goto fail;
	if (listen(fd, 1) < 0) goto fail;
	return fd;
fail: {
		int save = errno;
		close(fd);
		errno = save;
		return -1;
	}
}

/* Generate a random hex suffix for the listener path so concurrent
 * helper invocations don't collide. */
static void hex_random(char *buf, size_t n) {
	unsigned char raw[8];
	if (getrandom(raw, sizeof raw, 0) != (ssize_t)sizeof raw) {
		/* getrandom should not fail with these args; if it does, fall back
		 * to the PID — collisions are then bounded by PID reuse. */
		snprintf(buf, n, "%d-%lld", getpid(), (long long)time(NULL));
		return;
	}
	const char *hex = "0123456789abcdef";
	size_t i;
	for (i = 0; i < sizeof raw && (i * 2 + 1) < n - 1; i++) {
		buf[i * 2] = hex[raw[i] >> 4];
		buf[i * 2 + 1] = hex[raw[i] & 0xf];
	}
	buf[i * 2] = '\0';
}

static const char *opt_after(const char *arg, const char *name) {
	size_t name_len = strlen(name);
	if (strncmp(arg, name, name_len) != 0 || arg[name_len] != '=') return NULL;
	return arg + name_len + 1;
}

static void usage(FILE *f) {
	fprintf(f,
	        "usage: wayland-app-context --engine=ENGINE --app-id=APPID "
	        "--instance-id=INSTANCE -- TARGET [ARGS...]\n");
}

int main(int argc, char **argv) {
	const char *engine = NULL, *app_id = NULL, *instance_id = NULL;

	int i = 1;
	for (; i < argc; i++) {
		const char *a = argv[i];
		if (strcmp(a, "--") == 0) { i++; break; }
		if (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0) { usage(stdout); return 0; }
		const char *v;
		if ((v = opt_after(a, "--engine"))) engine = v;
		else if ((v = opt_after(a, "--app-id"))) app_id = v;
		else if ((v = opt_after(a, "--instance-id"))) instance_id = v;
		else {
			fprintf(stderr, "wayland-app-context: unknown option %s\n", a);
			usage(stderr);
			return 2;
		}
	}

	if (!engine || !app_id || !instance_id) {
		fprintf(stderr, "wayland-app-context: --engine, --app-id, --instance-id are required\n");
		usage(stderr);
		return 2;
	}
	if (i >= argc) {
		fprintf(stderr, "wayland-app-context: no target binary after --\n");
		usage(stderr);
		return 2;
	}

	char *const *target_argv = &argv[i];

	/* The listener socket lives in /tmp, not $XDG_RUNTIME_DIR. Two
	 * reasons. (1) systemd's --user sandbox remounts /run/user as a
	 * fresh empty tmpfs to isolate units from each other; bind()
	 * there returns EROFS. (2) Unix-socket paths are resolved in the
	 * connecting process's mount namespace — when the helper bind()s
	 * and exec()s the target in the same namespace, /tmp is the same
	 * tmpfs (PrivateTmp guarantees it's private to the unit) so the
	 * target reaches the listener. The compositor only needs the
	 * dup'd listener fd (path-independent on the accept side). */
	const char *tmp_dir = getenv("TMPDIR");
	if (!tmp_dir) tmp_dir = "/tmp";

	/* Connect to the compositor BEFORE binding the listener socket so a
	 * misconfigured environment fails fast. */
	struct wl_display *display = wl_display_connect(NULL);
	if (!display) {
		fprintf(stderr, "wayland-app-context: wl_display_connect failed\n");
		return 1;
	}

	struct registry_state rs = { 0 };
	struct wl_registry *registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, &rs);
	wl_display_roundtrip(display);
	wl_registry_destroy(registry);

	if (!rs.manager) {
		fprintf(stderr,
		        "wayland-app-context: compositor does not advertise "
		        "wp_security_context_manager_v1\n");
		wl_display_disconnect(display);
		return 1;
	}

	/* Build the listener socket path. Keep it short — AF_UNIX has a hard
	 * 108-char limit on sun_path. */
	char suffix[24];
	hex_random(suffix, sizeof suffix);
	char path[108];
	int n = snprintf(path, sizeof path, "%s/wayland-app-%s", tmp_dir, suffix);
	if (n < 0 || (size_t)n >= sizeof path) {
		fprintf(stderr, "wayland-app-context: socket path too long\n");
		wl_display_disconnect(display);
		return 1;
	}

	int listen_fd = bind_listener(path);
	if (listen_fd < 0) {
		fprintf(stderr, "wayland-app-context: bind_listener %s: %s\n", path, strerror(errno));
		wl_display_disconnect(display);
		return 1;
	}

	/* Close pipe: read end -> compositor, write end stays in our process
	 * tree so it survives execvp() and closes when the target exits. */
	int close_pipe[2];
	if (pipe2(close_pipe, O_CLOEXEC) < 0) {
		fprintf(stderr, "wayland-app-context: pipe2: %s\n", strerror(errno));
		close(listen_fd);
		unlink(path);
		wl_display_disconnect(display);
		return 1;
	}

	struct wp_security_context_v1 *ctx =
		wp_security_context_manager_v1_create_listener(rs.manager, listen_fd, close_pipe[0]);
	wp_security_context_v1_set_sandbox_engine(ctx, engine);
	wp_security_context_v1_set_app_id(ctx, app_id);
	wp_security_context_v1_set_instance_id(ctx, instance_id);
	wp_security_context_v1_commit(ctx);

	if (wl_display_roundtrip(display) < 0) {
		fprintf(stderr, "wayland-app-context: roundtrip after commit failed\n");
		wp_security_context_v1_destroy(ctx);
		close(listen_fd);
		close(close_pipe[0]);
		close(close_pipe[1]);
		unlink(path);
		wl_display_disconnect(display);
		return 1;
	}

	/* We no longer need our refs to listener_fd or close_pipe[0] — the
	 * compositor has its own dups. close_pipe[1] is the keepalive for
	 * the security context's lifetime; clear CLOEXEC so it survives the
	 * exec into the target. */
	wp_security_context_v1_destroy(ctx);
	wp_security_context_manager_v1_destroy(rs.manager);
	close(listen_fd);
	close(close_pipe[0]);
	wl_display_disconnect(display);

	int flags = fcntl(close_pipe[1], F_GETFD);
	if (flags < 0 || fcntl(close_pipe[1], F_SETFD, flags & ~FD_CLOEXEC) < 0) {
		fprintf(stderr, "wayland-app-context: clear CLOEXEC: %s\n", strerror(errno));
		unlink(path);
		return 1;
	}

	if (setenv("WAYLAND_DISPLAY", path, 1) < 0) {
		fprintf(stderr, "wayland-app-context: setenv WAYLAND_DISPLAY: %s\n", strerror(errno));
		unlink(path);
		return 1;
	}

	execvp(target_argv[0], target_argv);
	fprintf(stderr, "wayland-app-context: execvp %s: %s\n", target_argv[0], strerror(errno));
	return 127;
}
