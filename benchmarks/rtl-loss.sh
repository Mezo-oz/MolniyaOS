#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — sample loss from an rtl_test capture
# ============================================================================
#   rtl-loss.sh read <raw>    ppm=<N|unknown> bytes=<N> samples=<N>
#
# An executable helper, not a sourced library: it returns data on stdout and
# status via its exit code, so the harness that calls it stays clean under plain
# `shellcheck -S style` with no --external-sources. See the extraction rule in
# ROADMAP.md, which `run-sdr-bench.sh` tripped at 456 lines.
#
# It reads a file and does arithmetic, nothing else — no dongle, no sudo, no
# sweep. That is the point of it being separate: the parsing can be checked
# against a saved capture in a second, which is how the claims below stay true
# as rtl_test builds change. `~/sdr-smoke-2026-09-07/parsecheck.txt` on
# pi-server is the positive control (one gap line, 188 bytes, 1 ppm).
#
# rtl_test publishes its OWN aggregate -- "Samples per million lost (minimum): N"
# -- and that is the reportable figure. It is normalised, so it is comparable
# across rates and durations in a way an absolute byte count is not.
#
# WHY THE BYTE COUNT IS NOT THE METRIC, established 2026-09-07 by a positive
# control (rtl_test at 3.2 MS/s, nice -n 19, under stress-ng --cpu 16 --io 8):
# rtl_test does not print gaps as they happen. It DEFERS every "lost at least N
# bytes" line until the async read is cancelled, so in a 51-line capture the
# cancel marker sat at line 20, the ppm summary at 21, and all 30 gap lines at
# 22-51. Position therefore carries no information about when a gap occurred,
# and no filter on it can separate loss during the run from the final flush.
#
# An earlier revision of the harness tried exactly that, keying on the cancel
# marker. It was wrong twice over: it zeroed the column completely (every gap is
# post-cancel, always), and the reasoning behind it -- that config C's 188 bytes
# at 3.2 MS/s was purely a teardown artifact -- was half wrong. Those bytes were
# a real deferred gap report. They read as 0 ppm because 94 samples out of
# 1.92e9 is 0.05 ppm, which rounds to nothing. The conclusion held; the reason
# did not. Do not reintroduce a position-based filter.
#
# So: ppm is the metric. Bytes are advisory, a LOWER BOUND that includes the
# final flush -- "lost at least" and "(minimum)" are both rtl_test hedging, and
# the two accountings do not reconcile exactly.
# ============================================================================

set -uo pipefail

# Samples per million lost, per rtl_test's own summary. Prints "unknown" when the
# line is absent rather than 0: a missing metric and a measured zero are different
# facts and only one of them is a result. That distinction is the whole reason
# this function exists -- see the smoke test, where two zeros meant "never parsed".
lost_ppm() {
    awk '
        /Samples per million lost/ {
            for (i = NF; i >= 1; i--)
                if ($i ~ /^[0-9]+$/) { v = $i; found = 1; break }
        }
        END { print (found ? v : "unknown") }
    ' "$1"
}

# Every gap rtl_test reported, summed. Advisory only -- see above. A run with no
# such line lost nothing, which awk reports as 0 rather than as empty: an empty
# cell in a results table is ambiguous in a way that zero is not.
sum_lost_bytes() {
    awk '
        /lost at least/ {
            for (i = 1; i <= NF; i++)
                if ($i == "least") { total += $(i+1) + 0; break }
        }
        END { print total + 0 }
    ' "$1"
}

cmd_read() {
    local raw="$1" ppm bytes

    # Checked explicitly rather than left to awk. Inline, an unreadable file gave
    # awk's own two-line complaint and an empty byte count that the caller's
    # arithmetic turned into a silent 0 -- the one outcome this whole file exists
    # to prevent. The dongle check in the harness has the same reasoning.
    if [ ! -r "$raw" ]; then
        echo "$0: cannot read '$raw'" >&2
        return 2
    fi

    ppm=$(lost_ppm "$raw")
    bytes=$(sum_lost_bytes "$raw")

    # The dongle delivers 8-bit I and 8-bit Q, so one complex sample is two
    # bytes. That conversion belongs with the parser, not with the caller.
    printf 'ppm=%s bytes=%s samples=%s\n' "$ppm" "$bytes" "$(( bytes / 2 ))"
}

case "${1:-}" in
    read) cmd_read "${2:-}" ;;
    *)
        echo "usage: $0 read <raw>" >&2
        exit 2
        ;;
esac
