#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — seed the data partition (p7)
# ============================================================================
#   ./seed-data.sh <data-dir> <slot-root-dir>
#
# Called once by image/assemble-image.sh, after both slots are populated, with
# p7 mounted at <data-dir> and slot A's root at <slot-root-dir>. Checked by
# verify-data.sh. An executable subprocess, never sourced -- the shape the
# extraction rule prescribes. Extracted 2026-11-15, when copying /home here
# would have taken assemble-image.sh past 400.
#
# WHAT IT WRITES:
#   - the top-level directories, so the first boot does not have to
#   - rauc/, RAUC's data-directory: the record of which slot is good, so it has
#     to be the one thing an update cannot reach
#   - slots.conf, the slot map
#   - home/, a copy of the slot's /home as provisioning left it. home.mount
#     binds it over /home at boot, which is what makes $HOME survive an update.
#
# THE COPY COMES FROM SLOT A AND ONLY SLOT A. Both slots are populated from the
# same rootfs by the same provisioning, so their /home trees are identical, and
# p7 is one partition: copying twice would just be the second copy winning.
#
# --numeric-ids, as everywhere in 4a: the build host's uid 1000 is not
# necessarily the image's, and a name lookup on the host would chown the user's
# home to whoever the host thinks 1000 is.
#
# It writes only inside <data-dir>.
# ============================================================================

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYOUT="$SELF_DIR/layout.sh"

die()  { echo "seed-data.sh: $*" >&2; exit 1; }
note() { echo "  $*" >&2; }

main() {
    [ $# -eq 2 ] || die "usage: seed-data.sh <data-dir> <slot-root-dir>"
    local data="$1" root="$2"
    [ -d "$data" ] || die "$data: not a directory"
    [ -d "$root/home" ] || die "$root/home: not a directory -- populate the slot first"
    [ -x "$LAYOUT" ] || die "layout.sh not found at $LAYOUT"

    sudo mkdir -p "$data/captures" "$data/tle" "$data/profiles" "$data/home" "$data/rauc"
    "$LAYOUT" slotmap | sudo tee "$data/slots.conf" > /dev/null

    # Trailing slashes on both: copy the CONTENTS of /home into home/, rather
    # than creating home/home.
    sudo rsync -aHAX --numeric-ids "$root/home/" "$data/home/"
    note "data: seeded, home copied ($(sudo ls "$data/home" | tr '\n' ' '))"
}

main "$@"
