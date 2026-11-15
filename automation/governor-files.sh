#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — the performance governor's files, stated once
# ============================================================================
#   governor-files.sh list             print the manifest, one entry per line
#   governor-files.sh install <root>   install it under <root> (as root)
#   governor-files.sh remove  <root>   remove it from under <root> (as root)
#
# <root> is `/` on a live box, or a slot's root directory during an image
# build. Same shape and same reason as tle-files.sh: the unit is installed by
# hand on a bench box (install-governor.sh), at build time into every slot
# (image/provision-components.sh), and checked by a third path
# (image/verify-components.sh). Until 2026-11-15 only the first existed, so
# every image shipped without the unit and ran whatever governor the kernel
# default and the base image left it on -- the README's "pins the Cortex-A76 at
# full clock" was true of pi-server and of no card flashed from an image.
#
# Executable helper, not a sourced library -- see the extraction rule.
#
# THE MANIFEST, on stdout, TAB-separated:
#   f<TAB><path><TAB><mode><TAB><source>   a file, installed from <source> in
#                                          this directory, owned root:root
#   l<TAB><path><TAB><target>              a symlink
#
# Unlike tle-files.sh, f carries its source name: the helper is installed
# without its .sh, because it is a command people type, and the manifest is the
# one place that may know both names.
#
# THE ENABLE LINK IS ALWAYS IN THE MANIFEST. The TLE timer is keyed on a login
# user and is only enabled when there is one; the governor is a property of the
# hardware and has no such condition. The link is the one `systemctl enable`
# makes, so a live install that also runs systemctl ends in the same state.
#
# Paths and link targets are AS SEEN ON THE BOX, never prefixed with <root>.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="/etc/systemd/system"
UNIT="molniya-governor.service"

die() { echo "governor-files.sh: $*" >&2; exit 1; }

manifest() {
    printf 'f\t%s\t755\t%s\n' /usr/local/sbin/molniya-set-governor molniya-set-governor.sh
    printf 'f\t%s\t644\t%s\n' "$UNIT_DIR/$UNIT" "$UNIT"
    printf 'l\t%s\t%s\n' "$UNIT_DIR/multi-user.target.wants/$UNIT" "$UNIT_DIR/$UNIT"
}

# Every source is checked before anything is written, so a checkout missing a
# file fails cleanly instead of leaving half a layout behind.
install_all() {
    local root="$1" kind path arg src
    while IFS=$'\t' read -r kind path arg src; do
        [ "$kind" != f ] || [ -f "$SELF_DIR/$src" ] ||
            die "missing $SELF_DIR/$src -- run from a clone of the repo"
    done < <(manifest)

    while IFS=$'\t' read -r kind path arg src; do
        mkdir -p "$root$(dirname "$path")"
        case "$kind" in
            f) install -m "$arg" -o root -g root "$SELF_DIR/$src" "$root$path" ;;
            l) ln -sfn "$arg" "$root$path" ;;
            *) die "unreadable manifest line: $kind" ;;
        esac
    done < <(manifest)
}

remove_all() {
    local root="$1" path
    while IFS=$'\t' read -r _ path _; do
        rm -f "$root$path"
    done < <(manifest)
}

root_of() {
    local root="${1:-}"
    [ -n "$root" ] || die "usage: governor-files.sh {install|remove} <root>"
    [ -d "$root" ] || die "$root: not a directory"
    [ "$(id -u)" -eq 0 ] || die "install and remove need root"
    # `/` becomes the empty prefix, so paths never come out as //usr/...
    printf '%s\n' "${root%/}"
}

main() {
    local verb="${1:-}" root
    case "$verb" in
        list)    manifest ;;
        install) root="$(root_of "${2:-}")"; install_all "$root" ;;
        remove)  root="$(root_of "${2:-}")"; remove_all "$root" ;;
        *) die "usage: governor-files.sh {list | install <root> | remove <root>}" ;;
    esac
}

main "$@"
