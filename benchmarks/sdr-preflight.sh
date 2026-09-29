#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — can this box run Test 2?
# ============================================================================
#   sdr-preflight.sh      silent and exit 0 if ready; otherwise says why on
#                         stderr and exits 1
#
# An executable helper, not a sourced library — see the extraction rule in
# ROADMAP.md, which `run-sdr-bench.sh` tripped at 456 lines. Its product is its
# exit status, so nothing goes to stdout at all (standard 8).
#
# Checking nothing but readiness means it can be run from a terminal, over ssh,
# without starting a sweep or answering a prompt:
#
#   ./sdr-preflight.sh && echo ready
#
# That is worth having on its own. A script recorded as "run" may only have run
# inside the image-build chroot, which executes on the box but is not the box:
# `02c-sdr-userspace.sh` was marked complete on 2026-08-23 and the live system
# still had no `rtl_test` on 2026-09-04. This answers that question in a second,
# from indoors, instead of at the hardware with the dongle already plugged in.
# ============================================================================

set -uo pipefail

for tool in rtl_test stress-ng timeout; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        echo "ERROR: $tool is not installed." >&2
        echo "       rtl_test comes from userspace/02c-sdr-userspace.sh;" >&2
        echo "       stress-ng from 02b-bench-tools.sh." >&2
        exit 1
    fi
done

# A dongle that is not there, or is claimed by the DVB-T driver, produces a run
# of zeros that looks like a perfect result. Check before measuring anything.
if ! rtl_test -t > /dev/null 2>&1; then
    echo "ERROR: rtl_test cannot open a device." >&2
    echo "" >&2
    echo "       Either no dongle is connected, or the kernel DVB-T driver has" >&2
    echo "       claimed it. 02c-sdr-userspace.sh installs the blacklist that" >&2
    echo "       prevents the latter; it needs a reboot or a replug to take" >&2
    echo "       effect. Check with:  lsmod | grep dvb" >&2
    echo "" >&2
    echo "       This matters more than a normal missing-dependency error: with" >&2
    echo "       no device, every run below would report zero lost samples and" >&2
    echo "       look like a flawless result." >&2
    exit 1
fi
