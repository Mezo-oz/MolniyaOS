#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — install MolniyaOS's own on-box components into one slot's root
# ============================================================================
#   ./provision-components.sh <slot-root-dir> [login-user]
#
# Called by image/assemble-image.sh once per slot, and checked by
# verify-components.sh. An executable subprocess, never sourced -- the shape
# the extraction rule prescribes, same as rauc/provision-rauc.sh.
#
# WHAT IT INSTALLS:
#   - the slot health check and slot-identity.sh, which molniya-mark-good runs;
#     without them no update can ever be committed
#   - the TLE refresh, from automation/tle-files.sh's manifest -- the same one
#     the bench installer uses, so the two cannot disagree about the layout
#   - the performance governor, from automation/governor-files.sh, enabled
#     unconditionally: it is a property of the hardware, not of a user
#
# ONDEMAND IS MASKED ONLY IF THE BASE SHIPS IT. install-governor.sh does the
# same on a live box, for the same reason: Debian's ondemand.service exists to
# set the governor after boot, and ordering our unit later is a race. The trixie
# base checked on 2026-11-15 does not ship it, so today this is a no-op that
# keeps a future base bump from silently undoing the pin.
#
# WHY IT IS A SEPARATE FILE. assemble-image.sh sat at exactly 400 lines, and
# the image installing the TLE units -- which the health check has always
# treated as CRITICAL while nothing put them there -- had to land in it. The
# seam is by concern: the assembler builds partitions and filesystems, this
# says what MolniyaOS ships on them. The next component (the capture pipeline)
# belongs here too.
#
# THE TIMER IS ENABLED ONLY WITH A LOGIN USER. The unit is a template keyed on
# the account that runs predict. With no --authorized-keys the image keeps the
# base's locked `pi` placeholder, and an instance for a user nobody can log in
# as would be a timer maintaining elements nobody reads. The unit files ship
# either way -- the health check's CRITICAL tier asks for exactly that -- and a
# missing instance is its ADVISORY tier.
#
# NO FIRST UPDATE. There is no network at build time. The timer is
# Persistent=true and ordered after network-online.target, so the first boot
# with a network fetches the elements.
#
# It writes only inside the slot root it is handed.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TLE_FILES="$SELF_DIR/../automation/tle-files.sh"
GOV_FILES="$SELF_DIR/../automation/governor-files.sh"

die()  { echo "provision-components.sh: $*" >&2; exit 1; }
note() { echo "  $*" >&2; }

# usr/lib first: trixie is merged-/usr, so lib/ is a symlink into it, but the
# unit is looked for by both names rather than assuming the merge.
mask_ondemand() {
    local root="$1" d
    for d in usr/lib/systemd/system lib/systemd/system; do
        if sudo test -e "$root/$d/ondemand.service"; then
            sudo ln -sfn /dev/null "$root/etc/systemd/system/ondemand.service"
            note "components: masked ondemand.service"
            return 0
        fi
    done
}

main() {
    case $# in
        1 | 2) ;;
        *) die "usage: provision-components.sh <slot-root-dir> [login-user]" ;;
    esac
    local root="$1" user="${2:-}"

    [ -d "$root" ] || die "$root: not a directory"
    [ -x "$TLE_FILES" ] || die "tle-files.sh not found at $TLE_FILES"
    [ -x "$GOV_FILES" ] || die "governor-files.sh not found at $GOV_FILES"
    if [ -n "$user" ]; then
        sudo grep -q "^$user:" "$root/etc/passwd" ||
            die "no account '$user' in $root -- provision access before components"
    fi

    sudo mkdir -p "$root/usr/local/lib/molniya"
    sudo install -m 0755 "$SELF_DIR/health-check/molniya-health-check.sh" \
        "$SELF_DIR/health-check/slot-identity.sh" \
        "$root/usr/local/lib/molniya/"

    sudo "$TLE_FILES" install "$root" "$user"
    sudo "$GOV_FILES" install "$root"
    mask_ondemand "$root"

    if [ -n "$user" ]; then
        note "components: health check, governor, TLE refresh enabled for $user"
    else
        note "components: health check, governor, TLE refresh units (no instance -- no login user)"
    fi
}

main "$@"
