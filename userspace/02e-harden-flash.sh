#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS Post-Install 02e — Flash Wear Hardening (optional, deployment-time)
# ============================================================================
# Run this ON THE PI. Nothing else in MolniyaOS depends on it and nothing breaks
# if you never run it. It exists for one deployment shape: an unattended capture
# box writing to a cheap SD card for months, where an avoidable write is wear
# paid for nothing.
#
# Three jobs, each behind its own prompt, each reversible:
#
#   1. atime    — add noatime to any fstab entry still paying for it
#   2. journald — log to RAM instead of the card, bounded
#   3. swap     — identify the swap provider, and disable it ONLY if it is the
#                 one that writes to flash
#
# ⚠️ NOT FOR THE BENCH BOX MID-CAMPAIGN. All three change userspace policy under
#    the kernel being measured. The RT benchmark's whole claim is that two
#    kernels differ only in config; hardening between two passes quietly adds a
#    second difference. Harden before a campaign or after it, never between.
#
# MEASURED ON pi-server 2026-09-20 — Pi OS trixie (Debian 13),
# 6.12.62+rpt-rpi-2712, root on mmcblk0, a real SD card. Three of this script's
# founding premises were wrong on a current image, which is why every job here
# inspects before it acts and prints what it found:
#
#   - `/` ALREADY MOUNTS noatime. Pi OS ships `defaults,noatime` for the root
#     filesystem in /etc/fstab. And where atime is on at all, Linux has
#     defaulted to `relatime` for years: at most one write per file per day,
#     not one per read. Only /boot/firmware was left at relatime here, and it
#     is read a handful of times per boot — so job 1 on this box is close to
#     symbolic, and says so rather than claiming a saving it does not make.
#   - `dphys-swapfile` IS NOT INSTALLED. Swap on trixie is /dev/zram0: 2 GB of
#     zstd-compressed RAM from systemd-zram-generator. Turning it off buys zero
#     flash writes and costs memory headroom on a 4 GB box, so job 3 refuses.
#   - THE CARD WAS NOT BEING HAMMERED. 16 KiB written in 60 s at load 0.00,
#     about 23 MiB/day. The 4.34 GiB written over the preceding 13 days was the
#     03-satcom-stack.sh install, not a background leak. Worth knowing before
#     trading away function for wear that is not being spent.
#
#   What was true exactly as stated: journald is persistent here
#   (/var/log/journal, 15 MB) and rsyslog is not installed, so journald is the
#   only steady on-disk log writer. Job 2 is the one with real work to do.
#
# THE COST OF JOB 2, STATED PLAINLY: volatile logs do not survive a reboot, and
# an unattended box that rebooted unexpectedly is exactly where you want to read
# why. MOLNIYA_JOURNAL_MODE=cap keeps the journal on disk and bounds it instead.
#
# ENVIRONMENT:
#   MOLNIYA_ASSUME_YES=1        answer every prompt yes (for the image builder)
#   MOLNIYA_JOURNAL_MODE=cap    bound the on-disk journal instead of moving it
#                               to RAM (default: volatile)
#
# EXIT CODES: 0 finished, including "nothing to do". 3 declined at every prompt.
#
# TO UNDO EVERYTHING:
#   sudo rm /etc/systemd/journald.conf.d/10-molniya-flash.conf
#   sudo systemctl restart systemd-journald
#   sudo cp -a /etc/fstab.molniya-pre-harden /etc/fstab   # only if job 1 ran
#   sudo systemctl enable --now dphys-swapfile            # only if job 3 ran
# ============================================================================

set -euo pipefail

# findmnt, swapon and dpkg-query live in /usr/sbin or /sbin, which are not on a
# non-login ssh PATH for an unprivileged user on Pi OS. That is the same trap
# rfkill set during the Test 2 sweeps, where a tool reported missing because the
# PATH was short rather than because the system lacked it. Fix it once, here.
PATH="$PATH:/usr/sbin:/sbin"
export PATH

FSTAB="/etc/fstab"
FSTAB_BACKUP="/etc/fstab.molniya-pre-harden"
JOURNAL_DROPIN="/etc/systemd/journald.conf.d/10-molniya-flash.conf"
JOURNAL_MODE="${MOLNIYA_JOURNAL_MODE:-volatile}"

# Set by any job that actually changed something, so the summary can tell
# "declined everything" (exit 3) from "inspected and found nothing to do" (0).
CHANGED=0

# Ask, unless the image builder has pre-answered. Explicit handling of read's
# EOF return: under `set -e` an unhandled non-zero from read ends the script,
# which would turn "no tty" into a failure instead of a decline.
confirm() {
    local prompt="$1" reply=""

    if [ "${MOLNIYA_ASSUME_YES:-0}" = "1" ]; then
        echo "       MOLNIYA_ASSUME_YES=1 — proceeding without prompting."
        return 0
    fi

    read -r -p "       $prompt (y/N): " reply || reply=""
    case "${reply,,}" in
        y|yes) return 0 ;;
        *)     return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Job 1 — atime
# ---------------------------------------------------------------------------

# Mount points in fstab backed by a real block device and still paying atime.
# proc, sysfs, tmpfs and swap lines are skipped: none of them touch the card.
# Prints one mount point per line — data on stdout, for the caller to judge.
atime_candidates() {
    awk '
        /^[[:space:]]*#/ || NF < 4                                     { next }
        $3 == "proc" || $3 == "sysfs" || $3 == "tmpfs" || $3 == "swap" { next }
        $4 ~ /(^|,)noatime(,|$)/                                       { next }
        { print $2 }
    ' "$FSTAB"
}

# findmnt's own syntax check, run against the CURRENT fstab. Called before the
# edit as well as after: a tree that was already producing warnings must not
# make a good edit look like it broke something.
fstab_verify_rc() {
    if ! command -v findmnt > /dev/null 2>&1; then
        return 0
    fi
    if sudo findmnt --verify > /dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Append noatime to one fstab entry's option field. Only the matched line is
# rebuilt; every other line is printed byte-for-byte as it was read.
#
# An entry that already says relatime becomes `relatime,noatime`, which looks
# wrong and is not: mount parses options left to right and the last one wins, so
# noatime takes effect. Stripping the older token would be tidier and would cost
# a dozen lines of this file's remaining headroom under the 400-line cap, which
# is the more valuable of the two.
fstab_add_noatime() {
    local target="$1" tmp=""
    tmp=$(mktemp)

    awk -v t="$target" 'BEGIN { OFS = "\t" }
        /^[[:space:]]*#/ || NF < 4           { print; next }
        $2 == t && $4 !~ /(^|,)noatime(,|$)/ { $4 = $4 ",noatime" }
        { print }
    ' "$FSTAB" > "$tmp"

    if ! grep -E "^[^#]*[[:space:]]${target}[[:space:]].*noatime" "$tmp" > /dev/null; then
        echo "ERROR: rewriting $target did not take. $FSTAB left untouched." >&2
        rm -f "$tmp"
        return 1
    fi

    sudo install -m 0644 -o root -g root "$tmp" "$FSTAB"
    rm -f "$tmp"
    echo "       $target → $(awk -v t="$target" '$2 == t { print $4 }' "$FSTAB")"
}

job_atime() {
    local candidates="" mp="" baseline_ok=0

    echo ""
    echo "[1/3] atime"

    # Report the whole picture, not only what is about to change.
    awk '/^[[:space:]]*#/ || NF < 4 { next }
         { printf "       %-16s %-6s %s\n", $2, $3, $4 }' "$FSTAB"

    candidates=$(atime_candidates)
    if [ -z "$candidates" ]; then
        echo "       Every real filesystem already mounts noatime. Nothing to do."
        return 0
    fi

    echo ""
    echo "       Still paying atime: $(echo "$candidates" | tr '\n' ' ')"
    echo "       Note the size of this prize before taking it: the kernel default"
    echo "       is relatime, which writes at most once per file per day — not"
    echo "       once per read. On a boot partition read a few times per boot the"
    echo "       saving is close to nil. It is free and reversible, not valuable."
    echo ""
    if ! confirm "Add noatime to those entries in $FSTAB?"; then
        echo "       Skipped."
        return 0
    fi

    fstab_verify_rc && baseline_ok=1

    if [ ! -f "$FSTAB_BACKUP" ]; then
        sudo cp -a "$FSTAB" "$FSTAB_BACKUP"
        echo "       Backed up to $FSTAB_BACKUP"
    fi

    for mp in $candidates; do
        fstab_add_noatime "$mp"
    done

    # A good edit cannot make a clean fstab dirty. If it did, put the file back
    # rather than leave a box that may not mount at boot.
    if [ "$baseline_ok" = "1" ] && ! fstab_verify_rc; then
        echo "ERROR: findmnt rejects the new $FSTAB. Restoring the backup." >&2
        sudo cp -a "$FSTAB_BACKUP" "$FSTAB"
        sudo findmnt --verify >&2 || true
        return 1
    fi

    CHANGED=1
    echo "       Applied. Takes effect at next mount:"
    for mp in $candidates; do
        echo "         sudo mount -o remount,noatime $mp"
    done
}

# ---------------------------------------------------------------------------
# Job 2 — journald
# ---------------------------------------------------------------------------

write_journal_dropin() {
    sudo mkdir -p "$(dirname "$JOURNAL_DROPIN")"

    case "$JOURNAL_MODE" in
        volatile)
            # RuntimeMaxUse bounds what the journal may take from /run, which is
            # RAM. Without it, logs that used to be capped by a 29 GB card are
            # capped by a 4 GB machine instead, which is the wrong trade.
            printf '%s\n' \
                "# Written by MolniyaOS userspace/02e-harden-flash.sh" \
                "# Remove this file and restart systemd-journald to undo." \
                "[Journal]" \
                "Storage=volatile" \
                "RuntimeMaxUse=64M" | sudo tee "$JOURNAL_DROPIN" > /dev/null
            ;;
        cap)
            printf '%s\n' \
                "# Written by MolniyaOS userspace/02e-harden-flash.sh" \
                "# Remove this file and restart systemd-journald to undo." \
                "[Journal]" \
                "Storage=persistent" \
                "SystemMaxUse=32M" \
                "SystemMaxFileSize=8M" | sudo tee "$JOURNAL_DROPIN" > /dev/null
            ;;
        *)
            echo "ERROR: MOLNIYA_JOURNAL_MODE must be 'volatile' or 'cap'," >&2
            echo "       not '$JOURNAL_MODE'." >&2
            return 1
            ;;
    esac
}

job_journald() {
    local storage="volatile (/run — already in RAM)"

    echo ""
    echo "[2/3] journald"

    [ -d /var/log/journal ] && storage="persistent (/var/log/journal)"
    echo "       storage now:  $storage"
    if command -v journalctl > /dev/null 2>&1; then
        echo "       on disk:      $(journalctl --disk-usage 2>/dev/null || echo unknown)"
    fi
    echo "       mode to set:  $JOURNAL_MODE"

    if [ -f "$JOURNAL_DROPIN" ]; then
        echo "       $JOURNAL_DROPIN already exists — nothing to do."
        return 0
    fi

    echo ""
    if [ "$JOURNAL_MODE" = "volatile" ]; then
        echo "       Volatile logs die at reboot. On a box nobody logs into that"
        echo "       is the point; on a box that rebooted by itself at 04:00 it"
        echo "       is the evidence. MOLNIYA_JOURNAL_MODE=cap keeps them on the"
        echo "       card and bounds them to 32 MB instead."
        echo ""
    fi
    if ! confirm "Write $JOURNAL_DROPIN and restart journald?"; then
        echo "       Skipped."
        return 0
    fi

    write_journal_dropin
    sudo systemctl restart systemd-journald
    CHANGED=1

    echo "       Applied. Verify with:  journalctl --disk-usage"
    if [ "$JOURNAL_MODE" = "volatile" ] && [ -d /var/log/journal ]; then
        echo ""
        echo "       The journals already on the card are left alone — deleting"
        echo "       logs is not this script's call. To reclaim them:"
        echo "         sudo rm -rf /var/log/journal/*"
    fi
}

# ---------------------------------------------------------------------------
# Job 3 — swap
# ---------------------------------------------------------------------------

# zram's writeback path is the only part of a zram swap that can reach flash:
# cold pages get pushed to a backing device, which on Pi OS is a file on the
# card. Reported rather than changed, because on the box this was written
# against it had moved exactly zero pages in 13 days.
report_zram_writeback() {
    local backing="" written=""

    [ -r /sys/block/zram0/backing_dev ] || return 0
    backing=$(cat /sys/block/zram0/backing_dev)
    echo "       writeback:    $backing"

    [ "$backing" = "none" ] && return 0
    [ -r /sys/block/zram0/bd_stat ] || return 0

    written=$(awk '{ print $3 }' /sys/block/zram0/bd_stat)
    echo "       pages written back to it since boot: $written"
    if [ "$written" = "0" ]; then
        echo "       Zero. The path to flash exists and is not being used."
    fi
}

job_swap() {
    local dphys_status="" dphys="absent" swaps=""

    echo ""
    echo "[3/3] swap"

    dphys_status=$(dpkg-query -W -f='${Status}' dphys-swapfile 2>/dev/null || true)
    case "$dphys_status" in
        "install ok installed") dphys="installed" ;;
    esac

    swaps=$(swapon --show=NAME --noheadings 2>/dev/null | tr '\n' ' ' || true)
    echo "       active swap:  ${swaps:-none}"
    echo "       dphys-swapfile: $dphys"
    report_zram_writeback

    if [ "$dphys" != "installed" ]; then
        echo ""
        echo "       Nothing disabled, deliberately. The swap here is zram — a"
        echo "       compressed block device in RAM. It costs no flash writes,"
        echo "       and removing it would cost memory headroom on a 4 GB box."
        echo "       dphys-swapfile, the file-on-the-card swap this job exists to"
        echo "       remove, is not installed on Pi OS trixie at all."
        return 0
    fi

    echo ""
    echo "       dphys-swapfile writes swap to a file on the card. That is the"
    echo "       worst case for flash: high write volume, and a card that fails"
    echo "       under it corrupts memory rather than erroring cleanly."
    echo ""
    if ! confirm "Disable dphys-swapfile now and at boot?"; then
        echo "       Skipped."
        return 0
    fi

    sudo systemctl disable --now dphys-swapfile
    CHANGED=1
    echo "       Disabled. The swap file itself is left in place; remove it with:"
    echo "         sudo dphys-swapfile uninstall"
}

# ---------------------------------------------------------------------------

echo "============================================"
echo "  MolniyaOS — flash wear hardening"
echo "============================================"
echo ""
echo "  Inspects first, changes only what is real on THIS box, and prints what"
echo "  it found either way. Every job is reversible; see the header."

job_atime
job_journald
job_swap

echo ""
if [ "$CHANGED" = "1" ]; then
    echo "       Done. Undo instructions are in this script's header."
else
    echo "       Nothing changed — either declined, or nothing needed doing."
    exit 3
fi
echo ""
