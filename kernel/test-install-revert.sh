#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — prove install-kernel.sh's revert path, without a Pi
# ============================================================================
#   sudo bash kernel/test-install-revert.sh
#
# Runs in CI on every push, and anywhere else as root. Builds a fake stock boot
# partition and a fake kernel package under a temporary directory, runs the
# real install-kernel.sh into it via MOLNIYA_INSTALL_ROOT, and asserts the three
# promises its header makes:
#
#   1. every stock boot file is byte-identical afterwards -- only config.txt
#      changes, and only by appending
#   2. the revert one-liner the installer prints restores config.txt
#      byte-for-byte -- or, if stock had no final newline, plus exactly that
#   3. a second install does not arm a second block
#
# WHY THIS IS WORTH A CI STEP. The revert path is the reason os_prefix was
# adopted, and it is the path nobody exercises: it is used after something has
# already gone wrong, on a box that may not boot. An installer change that
# quietly overwrote a stock DTB again -- the exact bug os_prefix fixed -- would
# pass every other gate and surface as "stock kernel boots against our device
# trees" during an A/B benchmark. This makes that a red X instead.
#
# WHAT IT CANNOT TELL YOU: that the firmware honours os_prefix, or that the
# stock kernel boots. Those need the hardware drill.
#
# Fixture files are random bytes, not real kernels: the installer copies and
# never parses them, and random content means a copy over a stock file can
# never coincidentally leave its digest unchanged.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SELF_DIR/install-kernel.sh"
VER="6.12.0-fixture-molniya+"
# The revert command, copied from the installer's closing output -- which is
# also checked below, so the copy cannot drift from what users are told to run.
REVERT_RANGE='/--- MolniyaOS custom kernel/,/--- end MolniyaOS/d'

FAILS=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILS=$((FAILS + 1)); }
die()  { echo "test-install-revert.sh: $*" >&2; exit 2; }

rand() { head -c "$2" /dev/urandom > "$1"; }

# A stock boot partition shaped like Pi OS trixie's: the files install-kernel.sh
# names, plus the stock overlays directory it must leave alone.
make_stock() {
    local boot="$1" eol="$2"
    mkdir -p "$boot/overlays"
    rand "$boot/kernel_2712.img" 4096
    rand "$boot/kernel8.img" 4096
    rand "$boot/bcm2712-rpi-5-b.dtb" 1024
    rand "$boot/bcm2712d0-rpi-5-b.dtb" 1024
    rand "$boot/overlays/vc4-kms-v3d-pi5.dtbo" 512
    echo "console=serial0,115200 console=tty1 root=PARTUUID=0-02 rootfstype=ext4 rootwait" \
        > "$boot/cmdline.txt"
    printf 'dtparam=audio=on\ncamera_auto_detect=1\n[pi5]\ndtoverlay=vc4-kms-v3d-pi5\n[all]%s' \
        "$eol" > "$boot/config.txt"
}

make_package() {
    local pkg="$1"
    mkdir -p "$pkg/boot/overlays" "$pkg/modules/lib/modules/$VER/kernel"
    rand "$pkg/boot/kernel-molniya.img" 4096
    rand "$pkg/boot/bcm2712-rpi-5-b.dtb" 1024
    rand "$pkg/boot/bcm2712d0-rpi-5-b.dtb" 1024
    rand "$pkg/boot/overlays/vc4-kms-v3d-pi5.dtbo" 512
    echo "$VER" > "$pkg/kernel-version"
    cp "$INSTALLER" "$pkg/install-kernel.sh"
}

# Digest of every stock file, excluding what the installer is meant to create.
stock_digests() {
    local boot="$1"
    (cd "$boot" && find . -type f -not -path './molniya/*' -not -path './backup-*' \
        -not -name config.txt -print0 | sort -z | xargs -0 sha256sum)
}

run_install() {
    local root="$1" pkg="$2"
    MOLNIYA_INSTALL_ROOT="$root" NOHZ_FULL_CPUS="1-3" \
        bash "$pkg/install-kernel.sh" < /dev/null > "$root/install.log" 2>&1
}

# One complete case: a stock partition whose config.txt ends with $eol.
run_case() {
    local label="$1" eol="$2"
    local root pkg boot before after cfg_stock
    root="$(mktemp -d)"; pkg="$root/pkg"; boot="$root/boot/firmware"
    make_stock "$boot" "$eol"
    make_package "$pkg"
    before="$(stock_digests "$boot")"
    cfg_stock="$root/config.stock"; cp "$boot/config.txt" "$cfg_stock"

    if ! run_install "$root" "$pkg"; then
        fail "$label: install exited non-zero (log follows)"; cat "$root/install.log"
        rm -rf "$root"; return
    fi
    after="$(stock_digests "$boot")"
    if [ "$before" = "$after" ]; then pass "$label: every stock boot file unchanged"
    else fail "$label: a stock boot file changed"; diff <(echo "$before") <(echo "$after") || true; fi

    if cmp -s "$cfg_stock" <(head -c "$(stat -c %s "$cfg_stock")" "$boot/config.txt"); then
        pass "$label: config.txt only appended to"
    else fail "$label: config.txt was edited, not appended to"; fi

    if [ -f "$boot/molniya/kernel-molniya.img" ] && [ -f "$root/lib/modules/$VER/modules.dep" ]; then
        pass "$label: payload and modules.dep landed under the prefix"
    else fail "$label: payload or modules.dep missing"; fi

    if grep -qF "sed -i '$REVERT_RANGE'" "$root/install.log"; then
        pass "$label: installer prints the revert command this test runs"
    else fail "$label: installer's revert command differs from the tested one"; fi

    run_install "$root" "$pkg" || fail "$label: second install exited non-zero"
    if [ "$(grep -c '^os_prefix=' "$boot/config.txt")" -eq 1 ]; then
        pass "$label: second install arms no second block"
    else fail "$label: second install armed a second block"; fi

    # Without a final newline the installer has to add one, or its marker would
    # weld onto the last directive -- and sed deletes whole lines, so the revert
    # cannot take it back. That one byte is the documented exception; anything
    # more is a failure. Pi OS's own config.txt ends in a newline.
    local extra=""
    [ -n "$eol" ] || { printf '\n' >> "$cfg_stock"; extra=" (plus the final newline)"; }
    sed -i "$REVERT_RANGE" "$boot/config.txt"
    if cmp -s "$cfg_stock" "$boot/config.txt"; then
        pass "$label: revert restores config.txt byte-for-byte$extra"
    else
        fail "$label: revert leaves config.txt different from stock"
        diff <(od -c "$cfg_stock") <(od -c "$boot/config.txt") | head -6 || true
    fi
    rm -rf "$root"
}

main() {
    [ "$(id -u)" -eq 0 ] || die "run as root: the installer refuses anything else"
    [ -f "$INSTALLER" ] || die "no install-kernel.sh beside this script"
    command -v depmod > /dev/null || die "depmod not found (package kmod)"

    run_case "config.txt with final newline" $'\n'
    run_case "config.txt without final newline" ""

    echo
    [ "$FAILS" -eq 0 ] || { echo "FAIL -- $FAILS check(s)"; exit 1; }
    echo "PASS -- the revert path holds"
}

main "$@"
