#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — the build chroot's file guards, on and off
# ============================================================================
#   ./chroot-guards.sh install <rootfs-dir>
#   ./chroot-guards.sh remove  <rootfs-dir>
#
# Called by image/build-rootfs.sh around every chroot step: install after the
# bind mounts are up, remove before they come down. An executable subprocess,
# never sourced. Extracted 2026-11-15 from build-rootfs.sh, which sat at 399
# when the initramfs guard had to land. The mounts stay in build-rootfs.sh,
# because its EXIT trap is what tears them down; these are only files.
#
# Each guard is undone exactly, so the image ships none of them:
#
#   policy-rc.d     stops packages starting daemons. Inside a chroot a service
#                   start either fails noisily or, worse, succeeds and leaves a
#                   process running against the host's PID 1.
#
#   resolv.conf     apt needs DNS, so the host's goes in and the image's own is
#                   put back. Saved rather than regenerated, because shipping the
#                   BUILD HOST's nameservers in every flashed card would be a real
#                   leak. Verified byte-identical to the pristine base after a run.
#
#   update-initramfs  diverted to a no-op. Found 2026-11-15, when SatDump's build
#                   dependencies pulled an e2fsprogs upgrade whose trigger ran
#                   mkinitramfs, which cannot find a root device in a chroot and
#                   failed dpkg two hours into the build. The initrd it was
#                   regenerating belongs to the stock kernel, which stage 3
#                   deletes from the image; the MolniyaOS kernel boots without one.
#                   August's build passed only because the archive had not moved
#                   yet -- so this was a latent failure, not a new one.
#                   dpkg-divert --rename rather than overwriting the binary: the
#                   package database stays consistent, and removing the divert
#                   puts the real file back byte-for-byte.
# ============================================================================

set -euo pipefail

INITRAMFS="/usr/sbin/update-initramfs"

die() { echo "chroot-guards.sh: $*" >&2; exit 1; }

divert() { sudo chroot "$1" dpkg-divert --quiet --local --rename "$2" "$INITRAMFS"; }

install_guards() {
    local root="$1"
    printf '#!/bin/sh\nexit 101\n' | sudo tee "$root/usr/sbin/policy-rc.d" > /dev/null
    sudo chmod +x "$root/usr/sbin/policy-rc.d"

    sudo cp -a "$root/etc/resolv.conf" "$root/etc/resolv.conf.molniya-bak" 2>/dev/null || true
    sudo cp -L /etc/resolv.conf "$root/etc/resolv.conf"

    # Idempotent: a build resumed after a failure finds the divert already in
    # place and must not stack a second one.
    if ! sudo chroot "$root" dpkg-divert --listpackage "$INITRAMFS" | grep -q LOCAL; then
        divert "$root" --add
    fi
    printf '#!/bin/sh\necho "update-initramfs: skipped in the MolniyaOS build chroot" >&2\n' |
        sudo tee "$root$INITRAMFS" > /dev/null
    sudo chmod +x "$root$INITRAMFS"
}

remove_guards() {
    local root="$1"
    sudo rm -f "$root/usr/sbin/policy-rc.d"
    if [ -e "$root/etc/resolv.conf.molniya-bak" ]; then
        sudo mv "$root/etc/resolv.conf.molniya-bak" "$root/etc/resolv.conf"
    fi
    if sudo chroot "$root" dpkg-divert --listpackage "$INITRAMFS" | grep -q LOCAL; then
        sudo rm -f "$root$INITRAMFS"
        divert "$root" --remove
    fi
}

main() {
    [ $# -eq 2 ] || die "usage: chroot-guards.sh {install|remove} <rootfs-dir>"
    local root="$2"
    [ -d "$root/usr" ] || die "$root: does not look like a root filesystem"
    case "$1" in
        install) install_guards "$root" ;;
        remove)  remove_guards "$root" ;;
        *) die "usage: chroot-guards.sh {install|remove} <rootfs-dir>" ;;
    esac
}

main "$@"
