#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# MolniyaOS — ADS-B decode comparison: Debian's librtlsdr vs the Blog fork
# ============================================================================
#   ./adsb-libcmp.sh --start HH:MM [--fork-gain G] [--minutes M] [--slot S]
#
# Run ON pi-server, with the V4 on the 1090 antenna. HH:MM is UTC today (or
# tomorrow if already past) and should be a busy hour. Writes everything to
# ~/adsb-libcmp-<date>/; analyse with adsb_libcmp.py once `status` says done.
#
# WHY THIS EXISTS. ROADMAP step 11: the fork is dropped if daytime decoding
# matches, because keeping it means two librtlsdr copies on every image forever
# (gr-osmosdr hard-depends on Debian's). The 2026-09-13 run was INCONCLUSIVE for
# two reasons this design removes:
#
#   1. GAINS WERE MATCHED ON THE -g NUMBER. The fork runs hotter for the same
#      -g -- at 1090 MHz by 2-6 dB of noise power -- so "both at 38.6" compared
#      two different receivers. Here a calibration sweep runs first, in the same
#      sitting, and Debian's gain is chosen to match the fork's NOISE POWER at
#      --fork-gain. Not preamble rate: that moves with traffic, noise does not.
#   2. TWO-MINUTE SLOTS WITH 1-7 AIRCRAFT. One aircraft leaving range swung a
#      count by 1000x. Here slots are short and alternate for most of an hour,
#      and the analysis compares each slot to its two neighbours, per aircraft,
#      so an aircraft fading out moves both sides of the comparison together.
#
# BOUNDED THROUGHOUT (standard 4): the wait for the start time is capped at
# 14 h, every dump1090 runs under timeout, and the slot loop has a fixed count.
#
# --fork-gain defaults to 28.0 because the 2026-11-15 calibration matched it to
# Debian@48.0 within 0.2 dB; higher fork gains have no Debian equal. The match
# is re-measured on every run regardless, and refused beyond MAX_GAP_DB.
#
# Do not run it during an image build: the smoke run overlapped one and dropped
# samples in four of twelve slots.
#
# Raw slot logs are kept gzipped: they are the evidence, and the September
# reanalysis was only possible because its raws had been kept.
# ============================================================================

set -euo pipefail

DUMP1090="/usr/local/bin/dump1090"
FORK_LIB="/usr/local/lib"
# Overridable so a smoke run cannot be mistaken for the real one afterwards.
OUT="${ADSB_OUT:-$HOME/adsb-libcmp-$(date -u +%F)}"
MAX_WAIT_S=50400
# dump1090's R828D gain table, the part an outdoor 1090 antenna uses.
CAL_GAINS=(20.7 25.4 28.0 29.7 32.8 33.8 36.4 37.2 38.6 40.2 42.1 43.4 43.9 44.5 48.0 49.6)
CAL_SLOT_S=10
# A match worse than this is not a match. The 2026-11-15 smoke run is why it
# exists: the fork at 38.6 sat 1.8 dB above anything Debian's gain table reaches,
# and nearest-wins would have compared two different receivers again.
MAX_GAP_DB=1.0

die()    { echo "adsb-libcmp.sh: $*" >&2; exit 1; }
status() { echo "$* ($(date -u +%FT%TZ))" > "$OUT/status"; }

# The fork is forced per process; without it every RTL tool on pi-server loads
# Debian's copy, which shadows the fork in the default search path.
with_lib() {
    local lib="$1"; shift
    if [ "$lib" = fork ]; then LD_LIBRARY_PATH="$FORK_LIB" "$@"; else "$@"; fi
}

# One capture. INT, not TERM, so dump1090 prints its statistics on the way out.
capture() {
    local lib="$1" gain="$2" secs="$3" log="$4"
    with_lib "$lib" timeout --signal=INT "$secs" "$DUMP1090" --gain "$gain" --stats \
        > "$log" 2>&1 || true
}

stat_field() { awk -v k="$2" 'index($0, k) { print $1; exit }' "$1"; }

calibrate() {
    local lib g log
    printf 'lib\tgain\tnoise_dbfs\tpreambles\n' > "$OUT/calibration.tsv"
    for g in "${CAL_GAINS[@]}"; do
        for lib in fork deb; do
            log="$OUT/cal-$lib-$g.log"
            capture "$lib" "$g" "$CAL_SLOT_S" "$log"
            printf '%s\t%s\t%s\t%s\n' "$lib" "$g" "$(stat_field "$log" 'dBFS noise power')" \
                "$(stat_field "$log" 'preambles received')" >> "$OUT/calibration.tsv"
            gzip -f "$log"
        done
    done
}

# Debian's gain whose noise power is nearest the fork's at the reference gain,
# and the gap in dB, tab-separated.
match_gain() {
    local fork_gain="$1"
    awk -F'\t' -v fg="$fork_gain" '
        NR > 1 && $1 == "fork" && $2 == fg { ref = $3 }
        NR > 1 && $1 == "deb" && $3 != "" { n[$2] = $3 }
        END {
            if (ref == "") exit 1
            for (g in n) { d = n[g] - ref; if (d < 0) d = -d
                           if (best == "" || d < bd) { best = g; bd = d } }
            if (best == "") exit 1
            printf "%s\t%.1f\n", best, bd
        }' "$OUT/calibration.tsv"
}

# One slot's summary line, ending in icao=count pairs for the analysis.
summarise_slot() {
    local idx="$1" lib="$2" gain="$3" t0="$4" log="$5"
    local per
    per="$(awk '/ICAO Address:/ { n[$3]++ } END { for (a in n) printf "%s=%d ", a, n[a] }' "$log")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$lib" "$gain" "$t0" \
        "$(stat_field "$log" 'total usable messages')" "$(stat_field "$log" 'dBFS noise power')" \
        "$(stat_field "$log" 'samples dropped')" "${per% }"
}

wait_for() {
    local hhmm="$1" now target
    now="$(date -u +%s)"
    target="$(date -u -d "today $hhmm" +%s)" || die "unreadable --start '$hhmm'"
    [ "$target" -gt "$now" ] || target=$(( target + 86400 ))
    [ $(( target - now )) -le "$MAX_WAIT_S" ] || die "start is more than 14 h away"
    status "armed, waiting for $hhmm UTC"
    sleep $(( target - now ))
}

main() {
    local start="" fork_gain="28.0" minutes=50 slot=20
    while [ $# -gt 0 ]; do
        case "$1" in
            --start)     start="${2:-}"; shift 2 ;;
            --fork-gain) fork_gain="${2:-}"; shift 2 ;;
            --minutes)   minutes="${2:-}"; shift 2 ;;
            --slot)      slot="${2:-}"; shift 2 ;;
            *) die "unknown argument '$1'" ;;
        esac
    done
    [ -n "$start" ] || die "usage: adsb-libcmp.sh --start HH:MM [--fork-gain G] [--minutes M] [--slot S]"
    [ -x "$DUMP1090" ] || die "no dump1090 at $DUMP1090"
    [ -e "$FORK_LIB/librtlsdr.so.0" ] || die "no fork librtlsdr in $FORK_LIB"
    printf '%s\n' "${CAL_GAINS[@]}" | grep -qx -- "$fork_gain" || die "--fork-gain must be one of: ${CAL_GAINS[*]}"
    mkdir -p "$OUT"

    wait_for "$start"
    status "calibrating"
    calibrate
    local deb_gain
    local match gap
    match="$(match_gain "$fork_gain")" || die "calibration produced no usable noise figures"
    deb_gain="$(cut -f1 <<< "$match")"; gap="$(cut -f2 <<< "$match")"
    printf 'fork_gain\t%s\ndeb_gain\t%s\ngap_db\t%s\nslot_s\t%s\n' \
        "$fork_gain" "$deb_gain" "$gap" "$slot" > "$OUT/params.tsv"
    if awk -v g="$gap" -v m="$MAX_GAP_DB" 'BEGIN { exit !(g > m) }'; then
        status "refused: no Debian gain within $MAX_GAP_DB dB of fork@$fork_gain (best $deb_gain at $gap dB) -- see calibration.tsv, pick a lower --fork-gain"
        exit 1
    fi

    # Even, so both libraries get the same number of slots.
    local n=$(( minutes * 60 / (slot + 2) / 2 * 2 )) i lib gain t0 log
    status "running $n slots: fork@$fork_gain vs deb@$deb_gain"
    printf 'slot\tlib\tgain\tutc\tusable\tnoise_dbfs\tdropped\taircraft\n' > "$OUT/slots.tsv"
    for (( i = 0; i < n; i++ )); do
        if (( i % 2 == 0 )); then lib=fork; gain="$fork_gain"; else lib=deb; gain="$deb_gain"; fi
        t0="$(date -u +%T)"; log="$OUT/slot-$(printf '%03d' "$i")-$lib.log"
        capture "$lib" "$gain" "$slot" "$log"
        summarise_slot "$i" "$lib" "$gain" "$t0" "$log" >> "$OUT/slots.tsv"
        gzip -f "$log"
        # The dongle needs a moment after close; back-to-back opens produced a
        # slot with no statistics at all in the smoke run.
        sleep 1
    done
    status "done: $n slots"
}

main "$@"
