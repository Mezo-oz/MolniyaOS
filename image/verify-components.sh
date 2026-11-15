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
# THE TLE AND GOVERNOR CHECKS CARRY NO COPY OF THE LAYOUT. They iterate the
# manifests automation/{tle,governor}-files.sh print, the same tables the installer
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
GOV_FILES="$SELF_DIR/../automation/governor-files.sh"

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

# Takes the command that prints the manifest, so each caller passes its own
# helper's arguments. The fourth column, where present, is a source name -- an
# install detail, read and discarded here.
verify_manifest() {
    local label="$1" root="$2"; shift 2
    local kind path arg
    while IFS=$'\t' read -r kind path arg _; do
        case "$kind" in
            d | f)
                check_eq "$label: $path mode" "$arg" "$(smode "$root$path")"
                check_eq "$label: $path owner" "0:0" "$(sowner "$root$path")" ;;
            l)
                check_eq "$label: $path -> $arg" "$arg" "$(slink "$root$path")"
                check "$label: $arg exists in the slot" sudo test -e "$root$arg" ;;
            *)  fail "$label manifest emitted an unreadable line: $kind" ;;
        esac
    done < <("$@")
}

verify_tle() {
    local root="$1" user="$2"
    verify_manifest tle "$root" "$TLE_FILES" list "$user"

    # The updater's one runtime dependency outside coreutils. It takes either.
    check "tle: curl or wget present" sudo sh -c \
        "test -x '$root/usr/bin/curl' || test -x '$root/usr/bin/wget'"
}

# Absent or masked both pass; a live ondemand.service would race the pin.
verify_governor() {
    local root="$1" d shipped=""
    verify_manifest governor "$root" "$GOV_FILES" list
    for d in usr/lib/systemd/system lib/systemd/system; do
        sudo test -e "$root/$d/ondemand.service" && shipped=1
    done
    if [ -z "$shipped" ]; then
        pass "governor: base ships no ondemand.service"
    else
        check_eq "governor: ondemand.service masked" /dev/null \
            "$(slink "$root/etc/systemd/system/ondemand.service")"
    fi
}

main() {
    [ $# -eq 2 ] || die "usage: verify-components.sh <slot-root-dir> <login-user>"
    local root="$1" user="$2"
    [ -d "$root" ] || die "$root: not a directory"
    [ -x "$TLE_FILES" ] || die "tle-files.sh not found at $TLE_FILES"
    [ -x "$GOV_FILES" ] || die "governor-files.sh not found at $GOV_FILES"

    verify_health_check "$root"
    verify_tle "$root" "$user"
    verify_governor "$root"
}

main "$@"
