#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — the TLE refresh's files, stated once
# ============================================================================
#   tle-files.sh list    [user]          print the manifest, one entry per line
#   tle-files.sh install <root> [user]   install it under <root> (as root)
#   tle-files.sh remove  <root>          remove it from under <root> (as root)
#
# <root> is `/` on a live box, or a slot's root directory during an image
# build. [user] adds the timer's enable link for that account; a live install
# leaves it out and lets `systemctl enable` make the same link.
#
# WHY ONE MANIFEST. The refresh is installed by two paths -- by hand on a bench
# box (install-tle-timer.sh) and at build time into every image slot
# (image/provision-components.sh) -- and checked by a third
# (image/verify-components.sh). Three copies of the layout drift, and drift here
# has a known shape: on 2026-10-06 the installer was found copying the updater
# into /usr/local/bin WITHOUT the helper it calls, a box that would fetch,
# validate and then die at the first write. A slot that passes on the bench and
# fails in the field is the worst failure this project can ship, so every path
# reads the layout from here. Add a file to the table and all three follow.
#
# Executable helper, not a sourced library -- see the extraction rule.
#
# THE MANIFEST, on stdout, TAB-separated:
#   d<TAB><path><TAB><mode>       a directory
#   f<TAB><path><TAB><mode>       a file, installed from this directory's copy
#                                 of the same basename, owned root:root
#   l<TAB><path><TAB><target>     a symlink
#
# Paths and link targets are AS SEEN ON THE BOX, never prefixed with <root>. A
# link written during an image build must point at /usr/local/lib/..., not at
# the build host's mount of it -- that link would resolve on the build host and
# dangle on every card flashed from the image.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="/usr/local/lib/molniya-tle"
UNIT_DIR="/etc/systemd/system"
UNIT_BASE="molniya-tle-update"

die() { echo "tle-files.sh: $*" >&2; exit 1; }

manifest() {
    local user="${1:-}"
    printf 'd\t%s\t755\n' "$LIB_DIR"
    printf 'f\t%s\t755\n' "$LIB_DIR/tle-updater.sh" "$LIB_DIR/atomic-write.sh"
    printf 'l\t%s\t%s\n' "/usr/local/bin/$UNIT_BASE" "$LIB_DIR/tle-updater.sh"
    printf 'f\t%s\t644\n' "$UNIT_DIR/$UNIT_BASE@.service" "$UNIT_DIR/$UNIT_BASE@.timer"
    if [ -n "$user" ]; then
        printf 'l\t%s\t%s\n' "$UNIT_DIR/timers.target.wants/$UNIT_BASE@$user.timer" \
            "$UNIT_DIR/$UNIT_BASE@.timer"
    fi
}

# Every source is checked before anything is written, so a checkout missing a
# file fails cleanly instead of leaving half a layout behind.
install_all() {
    local root="$1" user="$2" kind path arg
    while IFS=$'\t' read -r kind path arg; do
        [ "$kind" != f ] || [ -f "$SELF_DIR/$(basename "$path")" ] ||
            die "missing $SELF_DIR/$(basename "$path") -- run from a clone of the repo"
    done < <(manifest "$user")

    while IFS=$'\t' read -r kind path arg; do
        case "$kind" in
            d) install -d -m "$arg" -o root -g root "$root$path" ;;
            # Parents made here, not assumed: install(1) will not create them,
            # and found by test against a bare root on 2026-10-20.
            f) mkdir -p "$root$(dirname "$path")"
               install -m "$arg" -o root -g root "$SELF_DIR/$(basename "$path")" "$root$path" ;;
            # -n: replace an existing link rather than following it. An install
            # from before 2026-10-06 left a plain file here; -f replaces that.
            l) mkdir -p "$root$(dirname "$path")"
               ln -sfn "$arg" "$root$path" ;;
            *) die "unreadable manifest line: $kind" ;;
        esac
    done < <(manifest "$user")
}

# Enable links go too, for every instance and not just one user's: a link left
# behind points at a unit that no longer exists. A live uninstall disables its
# instances through systemctl first, so on a running box this finds none.
remove_all() {
    local root="$1" kind path arg
    rm -f "$root$UNIT_DIR/timers.target.wants/$UNIT_BASE@"*.timer
    while IFS=$'\t' read -r kind path arg; do
        case "$kind" in
            # Not ${root:?}: on a live box root is the empty prefix by design.
            # The path is LIB_DIR, a constant, so this can never be `rm -rf /`.
            d) rm -rf "$root$path" ;;
            f | l) rm -f "$root$path" ;;
        esac
    done < <(manifest)
}

root_of() {
    local root="${1:-}"
    [ -n "$root" ] || die "usage: tle-files.sh {install|remove} <root> [user]"
    [ -d "$root" ] || die "$root: not a directory"
    [ "$(id -u)" -eq 0 ] || die "install and remove need root"
    # `/` becomes the empty prefix, so paths never come out as //usr/...
    printf '%s\n' "${root%/}"
}

main() {
    local verb="${1:-}" root
    case "$verb" in
        list)    manifest "${2:-}" ;;
        install) root="$(root_of "${2:-}")"; install_all "$root" "${3:-}" ;;
        remove)  root="$(root_of "${2:-}")"; remove_all "$root" ;;
        *) die "usage: tle-files.sh {list [user] | install <root> [user] | remove <root>}" ;;
    esac
}

main "$@"
