#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — revert drill: boot stock once, confirm, come back
# ============================================================================
#   sudo bash kernel/revert-drill.sh start     arm the drill and reboot into it
#   sudo bash kernel/revert-drill.sh report    print the drill log
#        (check is run by the drill's own unit at boot; not for hand use)
#
# Run on a box whose config.txt has install-kernel.sh's block armed AND which is
# running that kernel. Two reboots later the log says whether the stock kernel
# booted from the same card and whether the box came back to the custom one.
#
# WHY. kernel/test-install-revert.sh proves in CI that the stock files survive
# and that the revert edit is exact. It cannot prove the firmware honours the
# result, that stock still boots against its own DTBs, or that the box returns.
# Only hardware can, and a path exercised only in an emergency is a path found
# broken in one.
#
# WHY tryboot, NOT EDITING config.txt. `reboot "0 tryboot"` makes the firmware
# read tryboot.txt instead of config.txt for exactly one boot. So the drill never
# touches config.txt, and the way back is the firmware's own default: if stock
# hangs, a power cycle boots the custom kernel. A drill that edited config.txt
# and relied on a script to restore it would have no way back from the one
# failure it exists to find. Same principle as A/B: the fallback is whatever
# was never modified.
#
# NO REBOOT LOOP: check reboots at most once, and only from the tryboot phase.
# A tryboot that did not happen, or a box that did not come back, is logged as
# FAIL and the drill disarms itself.
#
# BOTH MARKER NAMES. Installs from before the 2026-08-28 rename carry
# "--- KosmOS custom kernel" markers; pi-server's still does. The revert command
# install-kernel.sh prints names only MolniyaOS, so on such a box it silently
# deletes nothing. This script removes either.
# ============================================================================

set -euo pipefail

BOOT_DIR="/boot/firmware"
STATE="/var/lib/molniya-drill"
LIB="/usr/local/lib/molniya-drill"
UNIT="/etc/systemd/system/molniya-revert-drill.service"
TRYBOOT_FLAG="/proc/device-tree/chosen/bootloader/tryboot"
STRIP_BLOCK='/--- \(MolniyaOS\|KosmOS\) custom kernel/,/--- end \(MolniyaOS\|KosmOS\)/d'
CUSTOM_RE='-(molniya|kosmos)\+?$'

die() { echo "revert-drill.sh: $*" >&2; exit 1; }
log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$STATE/log"; }

# The firmware publishes whether this boot was a tryboot; a big-endian u32.
tryboot_now() { od -An -tu4 --endian=big "$TRYBOOT_FLAG" 2>/dev/null | tr -d ' ' || echo "?"; }

start() {
    [ "$(id -u)" -eq 0 ] || die "run as root"
    [ -f "$BOOT_DIR/config.txt" ] || die "no $BOOT_DIR/config.txt"
    [ ! -e "$STATE/phase" ] || die "a drill is already pending ($STATE/phase)"
    grep -Eq -- '--- (MolniyaOS|KosmOS) custom kernel' "$BOOT_DIR/config.txt" ||
        die "config.txt has no custom-kernel block -- nothing to revert from"
    # Without this the drill would "pass" on a box that was already on stock --
    # the state pi-server was in for two months after config.txt was re-armed.
    uname -r | grep -Eq -- "$CUSTOM_RE" ||
        die "running $(uname -r), not the armed custom kernel -- reboot onto it first"

    mkdir -p "$STATE" "$LIB"
    sed "$STRIP_BLOCK" "$BOOT_DIR/config.txt" > "$BOOT_DIR/tryboot.txt"
    ! grep -Eq '^(os_prefix|kernel)=' "$BOOT_DIR/tryboot.txt" ||
        { rm -f "$BOOT_DIR/tryboot.txt"; die "stripped config still sets os_prefix/kernel"; }

    install -m 0755 "$0" "$LIB/revert-drill.sh"
    cat > "$UNIT" <<EOF
# Written by revert-drill.sh start, removed by its last check. Transient.
[Unit]
Description=MolniyaOS revert drill: record this boot
After=multi-user.target
ConditionPathExists=$STATE/phase

[Service]
Type=oneshot
ExecStart=$LIB/revert-drill.sh check

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable molniya-revert-drill.service
    uname -r > "$STATE/custom-kernel"
    echo tryboot > "$STATE/phase"
    log "START running $(uname -r); rebooting into tryboot.txt (stock)"
    sync
    systemctl reboot "0 tryboot"
}

disarm() {
    rm -f "$STATE/phase" "$BOOT_DIR/tryboot.txt"
    systemctl disable molniya-revert-drill.service 2>/dev/null || true
    rm -f "$UNIT"
    systemctl daemon-reload
}

check() {
    local phase kver flag
    phase="$(cat "$STATE/phase")"; kver="$(uname -r)"; flag="$(tryboot_now)"
    case "$phase" in
        tryboot)
            if [ "$flag" = 1 ] && ! echo "$kver" | grep -Eq -- "$CUSTOM_RE"; then
                log "PASS stock boot: $kver (tryboot=1)"
            else
                log "FAIL expected a stock tryboot, got $kver (tryboot=$flag)"
                disarm; return 1
            fi
            # tryboot.txt goes now, before the reboot, so the return boot cannot
            # read it even if the firmware were asked to.
            rm -f "$BOOT_DIR/tryboot.txt"
            echo return > "$STATE/phase"
            log "rebooting normally; expecting $(cat "$STATE/custom-kernel")"
            sync
            systemctl reboot ;;
        return)
            if [ "$kver" = "$(cat "$STATE/custom-kernel")" ] && [ "$flag" != 1 ]; then
                log "PASS returned: $kver (tryboot=$flag). Drill complete."
            else
                log "FAIL did not return: running $kver (tryboot=$flag)"
            fi
            disarm ;;
        *)  log "FAIL unknown phase '$phase'"; disarm; return 1 ;;
    esac
}

main() {
    case "${1:-}" in
        start)  start ;;
        check)  check ;;
        report) cat "$STATE/log" 2>/dev/null || echo "no drill has run" ;;
        *) die "usage: revert-drill.sh {start|report}" ;;
    esac
}

main "$@"
