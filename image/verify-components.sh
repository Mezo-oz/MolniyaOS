#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — verify MolniyaOS's own on-box components in one slot
# ============================================================================
#   ./verify-components.sh <slot-root-dir> <login-user>
#
# The check for what provision-components.sh installs. Same data contract as
# verify-rauc.sh -- ONE LINE PER CHECK on stdout, and nothing else:
#
#   PASS<TAB><description>
#   FAIL<TAB><description>
#
# verify-image.sh renders and tallies. READ-ONLY: it is handed an
# already-mounted read-only tree and opens nothing for writing.
#
# THE TLE CHECKS CARRY NO COPY OF THE LAYOUT. They iterate the manifest
# automation/tle-files.sh prints, which is the same table the installer
# installed from -- a check holding its own list of paths is a check that
# agrees with itself when the layout moves. Links are checked as their literal
# target AND as resolving inside the slot: a link written with the build host's
# mount prefix resolves at build time and dangles on every card.
#
# The login user is always given: verify-image.sh asserts that account exists,
# so an image built without access fails there first, and the enable link is
# asserted for the same account.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TLE_FILES="$SELF_DIR/../automation/tle-files.sh"

die() { echo "verify-components.sh: $*" >&2; exit 1; }

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

smode() { sudo stat -c '%a' "$1" 2>/dev/null || echo "missing"; }
sowner() { sudo stat -c '%u:%g' "$1" 2>/dev/null || echo "missing"; }
slink() { sudo readlink "$1" 2>/dev/null || echo "missing"; }

verify_health_check() {
    local dir="$1/usr/local/lib/molniya"
    check "health check installed" sudo test -x "$dir/molniya-health-check.sh"
    check "slot-identity installed" sudo test -x "$dir/slot-identity.sh"
}

verify_tle() {
    local root="$1" user="$2" kind path arg
    while IFS=$'\t' read -r kind path arg; do
        case "$kind" in
            d | f)
                check_eq "tle: $path mode" "$arg" "$(smode "$root$path")"
                check_eq "tle: $path owner" "0:0" "$(sowner "$root$path")" ;;
            l)
                check_eq "tle: $path -> $arg" "$arg" "$(slink "$root$path")"
                check "tle: $arg exists in the slot" sudo test -e "$root$arg" ;;
            *)  fail "tle-files.sh emitted an unreadable line: $kind" ;;
        esac
    done < <("$TLE_FILES" list "$user")

    # The updater's one runtime dependency outside coreutils. It takes either.
    check "tle: curl or wget present" sudo sh -c \
        "test -x '$root/usr/bin/curl' || test -x '$root/usr/bin/wget'"
}

main() {
    [ $# -eq 2 ] || die "usage: verify-components.sh <slot-root-dir> <login-user>"
    local root="$1" user="$2"
    [ -d "$root" ] || die "$root: not a directory"
    [ -x "$TLE_FILES" ] || die "tle-files.sh not found at $TLE_FILES"

    verify_health_check "$root"
    verify_tle "$root" "$user"
}

main "$@"
