#!/usr/bin/env bash
# Manual end-to-end test for the graphical installer.
#
# Builds (or reuses) the installer ISO, creates a fresh 20 GiB empty
# qcow2 target disk, and boots both under QEMU with a graphical
# display so a human can drive Calamares through the installation.
#
# Usage:
#   ./scripts/run-installer-vm.sh            # interactive run
#   DISK=/path/to/disk.qcow2 ./scripts/run-installer-vm.sh
#   KEEP_DISK=1 ./scripts/run-installer-vm.sh   # don't recreate disk
#   ISO=/path/to/x.iso ./scripts/run-installer-vm.sh
#
# After install completes, reboot the VM (Calamares' "Restart now" or
# Ctrl-Alt-Del). QEMU is launched with `-boot menu=on,order=cd` so
# you can press Esc at the SeaBIOS prompt and pick the virtual HDD to
# verify the freshly installed system boots.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

# Default paths — overridable via env vars for ad-hoc runs.
WORKDIR=${WORKDIR:-"/tmp/distro-installer-vm"}
DISK=${DISK:-"$WORKDIR/disk.qcow2"}
DISK_SIZE=${DISK_SIZE:-20G}
MEMORY=${MEMORY:-8192} # MiB; GNOME live + Calamares + niri toplevel realising during install needs headroom
SMP=${SMP:-4}

mkdir -p "$WORKDIR"

# --- ISO ---------------------------------------------------------------
# If $ISO isn't pre-set, build via the flake. The first run takes a
# while (full GNOME live env + distro closure); subsequent runs are
# cached unless the flake source changed.
if [[ -z ${ISO:-} ]]; then
  echo ">> Building installer ISO via nix..."
  ISO_ROOT=$(nix build --print-out-paths --no-link .#iso.x86_64-linux.installer)
  ISO=$(echo "$ISO_ROOT"/iso/*.iso)
fi

if [[ ! -f $ISO ]]; then
  echo "ERROR: ISO not found at $ISO" >&2
  exit 1
fi
echo ">> ISO: $ISO"

# --- target disk -------------------------------------------------------
if [[ -f $DISK && -z ${KEEP_DISK:-} ]]; then
  echo ">> Removing previous disk image (set KEEP_DISK=1 to keep it)"
  rm -f "$DISK"
fi
if [[ ! -f $DISK ]]; then
  echo ">> Creating empty $DISK_SIZE qcow2 at $DISK"
  nix shell nixpkgs#qemu -c qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null
fi

# UEFI firmware — Calamares writes EFI bootloader entries that won't
# survive a legacy BIOS boot, so use OVMF.

OVMF_CODE=$(nix eval --raw 'nixpkgs#OVMF.fd.outPath' 2>/dev/null)/FV/OVMF_CODE.fd
OVMF_VARS_RO=$(nix eval --raw 'nixpkgs#OVMF.fd.outPath' 2>/dev/null)/FV/OVMF_VARS.fd
OVMF_VARS="$WORKDIR/OVMF_VARS.fd"
if [[ ! -f $OVMF_VARS ]]; then
  cp "$OVMF_VARS_RO" "$OVMF_VARS"
  chmod +w "$OVMF_VARS"
fi

# --- launch ------------------------------------------------------------
# `-boot menu=on,order=cd` shows the SeaBIOS/OVMF boot menu so you can
# pick the HDD post-install.  `-device virtio-vga-gl` + `-display
# gtk,gl=on` gives niri proper EGL/GBM after the install reboots
# (matches the host-debug VM setup in modules/nixos/vm-debug.nix).
# `show-menubar=off` lets Alt+letter shortcuts reach the guest
# compositor instead of being eaten by the GTK menu.
exec nix shell nixpkgs#qemu -c qemu-system-x86_64 \
  -machine q35,accel=kvm \
  -cpu max \
  -m "$MEMORY" \
  -smp "$SMP" \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$OVMF_VARS" \
  -drive file="$DISK",if=virtio,format=qcow2 \
  -cdrom "$ISO" \
  -boot menu=on,order=cd \
  -device virtio-vga-gl \
  -display gtk,gl=on,grab-on-hover=on,show-menubar=off \
  -device virtio-net-pci,netdev=n0 \
  -netdev user,id=n0 \
  -device intel-hda -device hda-output \
  -name "distro-installer"
