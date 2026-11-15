#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — verify the data partition (p7)
# ============================================================================
#   ./verify-data.sh <data-dir> <slot-root-dir> <login-user>
#
# The check for what seed-data.sh writes. Same data contract as verify-rauc.sh
# and verify-components.sh -- ONE LINE PER CHECK on stdout, and nothing else:
#
#   PASS<TAB><description>
#   FAIL<TAB><description>
#
# verify-image.sh renders and tallies. READ-ONLY: it is handed already-mounted
# read-only trees and opens nothing for writing. Extracted from verify-image.sh
# on 2026-11-15, which sat at 400 when the $HOME checks had to land.
#
# THE OWNER IS READ FROM THE SLOT'S passwd, not assumed to be 1000 and not
# looked up on the build host. sshd refuses an authorized_keys owned by the
# wrong uid, so a key file that exists but belongs to someone else is a box
# nobody can log in to -- the same failure as no key file at all.
# ============================================================================

set -euo pipefail

die() { echo "verify-data.sh: $*" >&2; exit 1; }

pass() { printf 'PASS\t%s\n' "$1"; }
fail() { printf 'FAIL\t%s\n' "$1"; }

check() {
    local desc="$1"; shift
    if "$@" > /dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

check_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$desc"
    else
        fail "$desc (want '$want', got '$got')"
    fi
}

sstat() { sudo stat -c "$1" "$2" 2>/dev/null || echo "missing"; }

# RAUC's data-directory holds the record of which slot is good. If it is
# anywhere under / it is inside a slot, and the update it is tracking destroys
# it. Read the path from system.conf rather than assuming it.
verify_rauc_dir() {
    local data="$1" root="$2" datadir
    datadir="$(sudo sed -n 's/^data-directory=//p' "$root/etc/rauc/system.conf" 2>/dev/null || true)"
    check "system.conf names a data-directory" test -n "$datadir"
    case "$datadir" in
        /data/*) pass "rauc data-directory is on the data partition" ;;
        *) fail "rauc data-directory '$datadir' is inside a slot" ;;
    esac
    check "and it exists on p7" sudo test -d "$data/${datadir#/data/}"
}

verify_home() {
    local data="$1" root="$2" user="$3" ids home="$1/home/$3"
    ids="$(sudo awk -F: -v u="$user" '$1 == u { print $3 ":" $4 }' "$root/etc/passwd")"
    check "home: $user exists in the slot's passwd" test -n "$ids"
    check "home: /data/home/$user exists on p7" sudo test -d "$home"
    check_eq "home: /data/home/$user owner" "$ids" "$(sstat '%u:%g' "$home")"
    check_eq "home: authorized_keys mode" 600 "$(sstat '%a' "$home/.ssh/authorized_keys")"
    check_eq "home: authorized_keys owner" "$ids" "$(sstat '%u:%g' "$home/.ssh/authorized_keys")"
    # The copy must be the provisioned key, not just a key: a stale file left
    # on p7 from some earlier seeding would pass every check above.
    check "home: p7 key matches the slot's" sudo cmp -s \
        "$home/.ssh/authorized_keys" "$root/home/$user/.ssh/authorized_keys"
}

main() {
    [ $# -eq 3 ] || die "usage: verify-data.sh <data-dir> <slot-root-dir> <login-user>"
    local data="$1" root="$2" user="$3" n
    [ -d "$data" ] || die "$data: not a directory"
    [ -d "$root" ] || die "$root: not a directory"

    n="$(sudo find "$data" -mindepth 1 -maxdepth 1 -type d -not -name 'lost+found' | wc -l)"
    check "data partition seeded" test "$n" -gt 0
    verify_rauc_dir "$data" "$root"
    verify_home "$data" "$root" "$user"
}

main "$@"
