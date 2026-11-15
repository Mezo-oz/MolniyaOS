#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verdict for adsb-libcmp.sh: does Debian's librtlsdr decode ADS-B as well as the fork?

    python3 adsb_libcmp.py ~/adsb-libcmp-<date>/slots.tsv [--tolerance 0.10]

THE TOLERANCE IS A DECISION MADE BEFORE THE RUN, not after. Choosing it while
looking at the result is how a test ends up agreeing with whoever ran it, so it
is a flag with a default, and the default is written in ROADMAP before any data
exists.

METHOD. Slots alternate fork, deb, fork, deb... For every aircraft heard in a
slot AND in both neighbouring slots -- present throughout, so not entering or
leaving range mid-comparison -- the slot's message count is divided by the mean
of its neighbours'. Comparing to both neighbours cancels a linear trend: an
aircraft closing range raises the left and right counts together. Each slot's
ratios are combined by geometric mean (ratios multiply, so they average in log
space), giving one number per slot.

If Debian decodes a fraction r of what the fork does, Debian slots score about
r and fork slots about 1/r, so r is estimated as sqrt(median_deb / median_fork).
The 95% interval comes from bootstrapping slots with a fixed seed, so the same
file always gives the same answer.

VERDICT:
    MATCH         interval's lower bound >= 1 - tolerance
    FORK BETTER   interval's upper bound <  1 - tolerance
    INCONCLUSIVE  anything else, or fewer than MIN_SLOTS scored slots per side

INCONCLUSIVE is a real outcome, not a failure to finish: the September run's
problem was reaching a conclusion its data could not carry.
"""

import argparse
import math
import random
import statistics
import sys

MIN_SLOTS = 20
BOOTSTRAP_ROUNDS = 2000
SEED = 1090


def read_slots(path):
    """Return slots in order as (lib, {icao: count})."""
    slots = []
    with open(path, encoding="utf-8") as f:
        header = f.readline().rstrip("\n").split("\t")
        col = {name: i for i, name in enumerate(header)}
        for line in f:
            fields = line.rstrip("\n").split("\t")
            pairs = fields[col["aircraft"]].split() if len(fields) > col["aircraft"] else []
            counts = {}
            for pair in pairs:
                icao, _, n = pair.partition("=")
                counts[icao] = int(n)
            slots.append((fields[col["lib"]], counts))
    return slots


def slot_scores(slots):
    """One geometric-mean neighbour ratio per scorable slot, keyed by library."""
    scores = {"fork": [], "deb": []}
    for k in range(1, len(slots) - 1):
        lib, here = slots[k]
        left, right = slots[k - 1][1], slots[k + 1][1]
        logs = []
        for icao, n in here.items():
            if left.get(icao, 0) > 0 and right.get(icao, 0) > 0:
                logs.append(math.log(n / ((left[icao] + right[icao]) / 2)))
        if logs and lib in scores:
            scores[lib].append(math.exp(statistics.fmean(logs)))
    return scores


def estimate(deb, fork):
    return math.sqrt(statistics.median(deb) / statistics.median(fork))


def bootstrap(deb, fork):
    rng = random.Random(SEED)
    draws = sorted(
        estimate(rng.choices(deb, k=len(deb)), rng.choices(fork, k=len(fork)))
        for _ in range(BOOTSTRAP_ROUNDS)
    )
    return draws[int(0.025 * BOOTSTRAP_ROUNDS)], draws[int(0.975 * BOOTSTRAP_ROUNDS) - 1]


def verdict(lo, hi, tolerance):
    floor = 1 - tolerance
    if lo >= floor:
        return "MATCH"
    if hi < floor:
        return "FORK BETTER"
    return "INCONCLUSIVE"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("slots_tsv")
    ap.add_argument("--tolerance", type=float, default=0.10,
                    help="largest acceptable shortfall for Debian, as a fraction (default 0.10)")
    args = ap.parse_args()

    scores = slot_scores(read_slots(args.slots_tsv))
    n_deb, n_fork = len(scores["deb"]), len(scores["fork"])
    print(f"scored slots: deb {n_deb}, fork {n_fork} (need {MIN_SLOTS} each)")
    if min(n_deb, n_fork) < MIN_SLOTS:
        print("VERDICT: INCONCLUSIVE -- too few slots with an aircraft heard throughout")
        return 2

    r = estimate(scores["deb"], scores["fork"])
    lo, hi = bootstrap(scores["deb"], scores["fork"])
    print(f"median slot ratio: deb {statistics.median(scores['deb']):.3f}, "
          f"fork {statistics.median(scores['fork']):.3f}")
    print(f"Debian decodes {r:.1%} of the fork's rate (95% CI {lo:.1%} to {hi:.1%})")
    v = verdict(lo, hi, args.tolerance)
    print(f"VERDICT: {v} at tolerance {args.tolerance:.0%}")
    return 0 if v == "MATCH" else 1


if __name__ == "__main__":
    sys.exit(main())
