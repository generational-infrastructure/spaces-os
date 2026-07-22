# Host-side provisioning script builders for the hermes microvms —
# plain functions, consumed only by ./host.nix.
{
  lib,
  pkgs,
  hlib,
  cfg,
}:
let
  inherit (hlib)
    vmName
    baseDir
    ;
in
rec {
  # Root ExecStartPre of microvm@hermes-<user>: per-user ssh keys, VM
  # state dir lockdown, tz seed, spaces wait.
  provisionScript =
    user: ucfg:
    pkgs.writeShellScript "hermes-microvm-provision-${user}" ''
      set -eu
      export PATH=${
        lib.makeBinPath (
          with pkgs;
          [
            coreutils
            gawk
            openssh
          ]
        )
      }
      base=${baseDir user}
      # dirs come from the tmpfiles rules; only secret material that cannot
      # live in the world-readable nix store is generated here.

      # ssh client key: the owner's credential for `hermes` CLI routing
      if [ ! -f "$base/ssh/client_ed25519" ]; then
        ssh-keygen -q -t ed25519 -N "" -C "hermes-microvm-${user}" -f "$base/ssh/client_ed25519"
      fi
      chown ${user} "$base/ssh/client_ed25519"
      chmod 0600 "$base/ssh/client_ed25519"

      # guest ssh host key (stable across guest rebuilds) + authorized key
      if [ ! -f "$base/guest/ssh/ssh_host_ed25519_key" ]; then
        ssh-keygen -q -t ed25519 -N "" -C "${vmName user}" -f "$base/guest/ssh/ssh_host_ed25519_key"
      fi
      chmod 0600 "$base/guest/ssh/ssh_host_ed25519_key"
      chmod 0644 "$base/guest/ssh/ssh_host_ed25519_key.pub"
      install -m 0644 "$base/ssh/client_ed25519.pub" "$base/guest/ssh/authorized_keys"
      awk '{ print "hermes-${user} " $1 " " $2 }' \
        "$base/guest/ssh/ssh_host_ed25519_key.pub" > "$base/ssh/known_hosts"
      chmod 0644 "$base/ssh/known_hosts"

      # VM runtime dir (virtiofsd/control sockets, current symlink): owned
      # by the VM's owner (qemu runs as the owner), no world access.
      # install-microvm@ re-chowns to `microvm` on rebuild — re-assert at
      # every start.
      if [ -d /var/lib/microvms/${vmName user} ]; then
        chown ${user}:kvm /var/lib/microvms/${vmName user}
        chmod 0750 /var/lib/microvms/${vmName user}
      fi

      # Seed the guest timezone mirror before boot (kept fresh afterwards by
      # the hermes-microvm-timezone path unit).
      ${tzSyncScript}

      ${lib.optionalString ucfg.spacesGateway.enable ''
        # Bounded wait for the owner's spaces gateway socket (linger brings
        # the user manager up at boot). Non-fatal: MCP reconnects later.
        for _i in $(seq 1 60); do
          [ -S ${ucfg.spacesGateway.socket} ] && break
          sleep 1
        done
      ''}
    '';

  # Mirror the host's /etc/localtime (deref'd TZif bytes, atomic replace)
  # into every guest share dir. A mount can't: the host tz is a symlink
  # into /etc, and sharing /etc would leak secrets. Runs at provisioning
  # and on every /etc/localtime swap.
  tzSyncScript = pkgs.writeShellScript "hermes-microvm-tz-sync" ''
    set -eu
    # Own the umask: callers may run under umask 077, which once produced
    # an untraversable tz dir (guest fell back to UTC); chmod repairs.
    umask 022
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    src=/etc/localtime
    [ -e "$src" ] || src=${pkgs.tzdata}/share/zoneinfo/UTC
    ${lib.concatMapStrings (u: ''
      d=${baseDir u}/guest/tz
      mkdir -p "$d"
      chmod 0755 "$d"
      cp -Lf "$src" "$d/.localtime.tmp"
      chmod 0644 "$d/.localtime.tmp"
      mv "$d/.localtime.tmp" "$d/localtime"
    '') (lib.attrNames cfg.enabledUsers)}
  '';

  # Generate the dashboard session token before microvm@ starts —
  # microvm@'s LoadCredential= resolves before its own ExecStartPre, so
  # this runs on microvm-virtiofsd@'s ExecStartPre. Owner 0400 doubles
  # as HERMES_DESKTOP_REMOTE_TOKEN for the hermes-desktop wrapper.
  desktopTokenScript =
    user:
    pkgs.writeShellScript "hermes-desktop-token-${user}" ''
      set -eu
      export PATH=${
        lib.makeBinPath (
          with pkgs;
          [
            coreutils
            openssl
          ]
        )
      }
      token=${baseDir user}/desktop-token
      if [ ! -f "$token" ]; then
        (umask 277; openssl rand -hex 32 | tr -d '\n' > "$token")
      fi
      chown ${user} "$token"
      chmod 0400 "$token"
    '';
}
