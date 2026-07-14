# The standalone aggregating integration MCP gateway
# (docs/agent-integrations-generic-mcp-design.md §1). A trusted --user service,
# socket-activated on %t/spaces-integration-gateway.sock, that:
#   - discovers the user's enabled integrations (the broker's enabled.json + the
#     world-readable definitions) and dials each integration's per-user MCP
#     socket (%t/spaces-integration-<name>.sock),
#   - aggregates their tools onto one MCP surface any harness consumes (pi via a
#     generic MCP-client extension, MCP-native harnesses via spaces-mcp-connect),
#   - enforces the autoRun allowlist and, for everything else, a per-call
#     confirm rendered by a STANDALONE popup (no harness GUI involvement).
#
# Kept as its own module (per the repo's one-feature-per-file rule) and gated on
# the integrations feature: without it, no harness sees any integration tool.
# The supervisor (pi-sessiond) no longer runs the gateway — it only forwards
# this socket's path into each sandboxed pi child.
{ inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  pkgsSelf = inputs.self.packages.${pkgs.stdenv.hostPlatform.system};
  gatewayPkg = pkgsSelf.spaces-integration-gateway;
  confirmPkg = pkgsSelf.spaces-integration-confirm;
  # The confirm command: the standalone popup, which reads the request +
  # verdict-file env the gateway sets. A JSON argv array (systemd `environment`
  # quotes the value; the gateway JSON-parses it — a raw serviceConfig list
  # would be whitespace-split, dropping the brackets).
  confirmCmd = builtins.toJSON [ (lib.getExe confirmPkg) ];
  integrationsEnabled = config.services.spaces-integrations.enable or false;
in
{
  config = lib.mkIf integrationsEnabled {
    # Put the stdio↔socket bridge on PATH so an MCP-native harness (Claude
    # Code, Cursor, …) can be configured with `command = spaces-mcp-connect
    # $XDG_RUNTIME_DIR/spaces-integration-gateway.sock` to consume the gateway.
    environment.systemPackages = [ gatewayPkg.connect ];

    systemd.user.services.spaces-integration-gateway = {
      description = "Spaces aggregating integration MCP gateway";
      # Always-on --user service (like the broker): it binds its own socket at
      # SPACES_INTEGRATION_GATEWAY_SOCKET. NOT socket-activated — Bun cannot
      # listen on an inherited fd, so LISTEN_FDS activation is unusable here.
      # Any harness's MCP client (or spaces-mcp-connect) dials the socket; UMask
      # 0077 + the 0700 %t dir keep it to the owning user (the gateway is the
      # sole approval point; a same-uid direct-connect bypass is the pre-existing
      # peer-auth residual — see backlog/agent-integrations-generic-mcp.md).
      wantedBy = [ "default.target" ];
      environment = {
        SPACES_INTEGRATION_GATEWAY_SOCKET = "%t/spaces-integration-gateway.sock";
        SPACES_INTEGRATION_GATEWAY_ENABLED = "%S/spaces-integrationd/enabled.json";
        SPACES_INTEGRATION_GATEWAY_DEFS = "/etc/spaces-integrations";
        SPACES_INTEGRATION_GATEWAY_SOCKETS = "%t";
        SPACES_INTEGRATION_CONFIRM_CMD = confirmCmd;
      };
      serviceConfig = {
        Type = "exec";
        ExecStart = lib.getExe gatewayPkg;
        Restart = "on-failure";
        RestartSec = 2;
        UMask = "0077";
        # PATH so the confirm command (quickshell) + `sh` resolve; the popup is
        # spawned into the user's graphical session (WAYLAND_DISPLAY is imported
        # into the user manager at login, as for pi-chat.service).
        Environment = "PATH=/run/wrappers/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin";
        # Trusted mediator (holds the integration sockets) but unprivileged and
        # hardened — runs as the user, never root (mirrors the broker).
        NoNewPrivileges = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectClock = true;
        SystemCallArchitectures = "native";
      };
    };
  };
}
