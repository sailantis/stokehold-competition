#!/usr/bin/env python3
"""Read an interleaved `diag-slots.sh` run and report the within-round ratios.

Why this is not `compare_runs.py` or `ab-report.py`
---------------------------------------------------
`compare_runs.py` compares two published *sweeps*: one arm per block, each arm
measured once per cell. `ab-report.py` reads `ab-perf.sh`, whose variants differ in
a build flag and whose rows have no pool columns. This reads `diag-slots.sh` in its
A/B mode, where two builds are measured in rotating order inside the same round and
each row also carries the pool's own account of how long the request waited for a
slot.

The estimator is the same as `ab-report.py`'s and for the same reason: a blocked
layout charges a drifting host to whichever build ran last, which is how this
repository once published a 22% "effect" that reversed sign the moment the two
binaries were interleaved instead (hazard 49). So:

    for each round r:   ratio_r = rps(AB, r) / rps(A, r)
    reported:           median over r, with min and max

A ratio whose spread spans 1.00 is no evidence, however far its median sits from 1.
The pool columns are summarised as medians per variant, because the question they
answer is structural ("does the queue shrink?") and a median over repeats is what
the report quotes.

    python3 scripts/slots-report.py ~/stoke-bench-run-slots/slots.tsv
    python3 scripts/slots-report.py slots.tsv --numerator new --denominator prefair

Exit status is 0 either way. This prints evidence; it does not pass or fail a run.
"""

import argparse
import collections
import statistics
from pathlib import Path

POOL_COLUMNS = [
    "mean_wait_us",
    "wait_p50_us",
    "wait_p99_us",
    "busiest_wait_us",
]


def load(path):
    """`variant, workers, conc, threads, round, rps, p50, p99, pool...` -> rows."""
    header = None
    rows = collections.defaultdict(dict)  # (conc, variant) -> {round: row}
    variants = []
    for line in Path(path).read_text().splitlines():
        parts = line.split("\t")
        if not parts or not parts[0]:
            continue
        if parts[0] == "variant":
            header = parts
            continue
        if header is None:
            raise SystemExit(f"{path}: data before a header row")
        row = dict(zip(header, parts))
        rnd = row.get("round")
        variant = row.get("variant")
        conc = row.get("conc")
        if not (rnd and variant and conc):
            continue
        if not row.get("rps") or row["rps"] == "?":
            continue
        try:
            row["rps"] = float(row["rps"])
        except ValueError:
            continue
        for col in POOL_COLUMNS:
            try:
                row[col] = float(row[col])
            except (KeyError, ValueError):
                row[col] = None
        rows[(conc, variant)][rnd] = row
        if variant not in variants:
            variants.append(variant)
    if not rows:
        raise SystemExit(f"no measured rows in {path}")
    return rows, variants


def med(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def fmt(value, width=9, places=0):
    return f"{value:>{width}.{places}f}" if value is not None else f"{'-':>{width}}"


def parse_duration_ms(text):
    """`1.41ms` / `512us` / `2.24ms` -> float microseconds, or None."""
    if not text:
        return None
    text = text.strip()
    try:
        if text.endswith("ms"):
            return float(text[:-2]) * 1000.0
        if text.endswith("us"):
            return float(text[:-2])
        if text.endswith("s"):
            return float(text[:-1]) * 1_000_000.0
    except ValueError:
        return None
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tsv", help="slots.tsv from an interleaved diag-slots.sh run")
    parser.add_argument(
        "--numerator",
        default=None,
        help="build under test (default: the first variant in the file)",
    )
    parser.add_argument(
        "--denominator",
        default=None,
        help="reference build (default: the second variant in the file)",
    )
    args = parser.parse_args()

    rows, variants = load(args.tsv)
    if len(variants) < 2:
        raise SystemExit(
            f"{args.tsv} holds one variant ({variants[0]}); this is the single-build\n"
            "sweep, not an interleaved A/B. Run diag-slots.sh with VARIANTS=a,b and\n"
            "BIN_<NAME> variables set to compare two builds."
        )
    num = args.numerator or variants[0]
    den = args.denominator or variants[1]
    for name in (num, den):
        if name not in variants:
            raise SystemExit(f"variant {name!r} is not in {args.tsv} ({', '.join(variants)})")

    concs = sorted({k[0] for k in rows}, key=lambda c: (int(c) if c.isdigit() else 1 << 30))
    rounds = sorted({r for v in rows.values() for r in v}, key=lambda r: int(r))

    print(f"file:        {args.tsv}")
    print(f"variants:    {', '.join(variants)}")
    print(f"rounds:      {', '.join(rounds)}")
    print(f"numerator:   {num}   denominator: {den}")
    print()

    # --- the estimator ---------------------------------------------------------
    print(f"within-round ratios {num} / {den}  (throughput)")
    print("each cell: median over rounds [min..max]   ->  a spread that spans 1.00 is no evidence")
    print(f"{'concurrency':<14}{'ratio':>10}{'change':>12}{'spread':>22}{'rounds':>8}")
    print("-" * 66)
    for conc in concs:
        ratios = []
        for rnd in rounds:
            a = rows.get((conc, num), {}).get(rnd)
            b = rows.get((conc, den), {}).get(rnd)
            if a and b and b["rps"]:
                ratios.append(a["rps"] / b["rps"])
        if not ratios:
            print(f"c={conc:<12}{'-':>10}")
            continue
        m = statistics.median(ratios)
        verdict = ""
        if min(ratios) > 1.0:
            verdict = "  <- every round the same way"
        elif max(ratios) < 1.0:
            verdict = "  <- every round the same way (down)"
        print(
            f"c={conc:<12}{m:>9.3f}x{(m - 1) * 100:>+11.1f}%"
            f"{f'[{min(ratios):.3f}..{max(ratios):.3f}]':>22}{len(ratios):>8}{verdict}"
        )
    print()

    # --- absolute rps: not comparable across runs, but shows the shape ---------
    print("absolute median rps (not comparable across runs; ratios above are)")
    header = f"{'concurrency':<14}" + "".join(f"{v:>12}" for v in variants) + f"{num + '/' + den:>12}"
    print(header)
    print("-" * len(header))
    for conc in concs:
        cells = []
        line = f"c={conc:<12}"
        for v in variants:
            values = [r["rps"] for r in rows.get((conc, v), {}).values()]
            m = med(values)
            cells.append(m)
            line += f"{fmt(m, 12)}"
        a = cells[variants.index(num)] if num in variants else None
        b = cells[variants.index(den)] if den in variants else None
        if a and b:
            line += f"{a / b:>11.3f}x"
        print(line)
    print()

    # --- the pool's own account -------------------------------------------------
    print("the pool's own wait, median over repeats (measured inside the server)")
    for v in variants:
        got = [r for conc in concs for r in rows.get((conc, v), {}).values()]
        with_pool = [r for r in got if r.get("mean_wait_us") is not None]
        if not with_pool:
            print(f"  {v}: no slot report (only RoadRunner is expected to be missing one)")
            print()
            continue
        print(f"  {v}")
        header = f"    {'conc':<6}{'mean us':>10}{'p50 us':>10}{'p99 us':>10}{'client p50':>12}{'client p99':>12}"
        print(header)
        for conc in concs:
            got = [r for r in rows.get((conc, v), {}).values() if r.get("mean_wait_us") is not None]
            if not got:
                continue
            print(
                f"    c={conc:<4}"
                f"{fmt(med([r.get('mean_wait_us') for r in got]), 10)}"
                f"{fmt(med([r.get('wait_p50_us') for r in got]), 10)}"
                f"{fmt(med([r.get('wait_p99_us') for r in got]), 10)}"
                f"{fmt(med([parse_duration_ms(r.get('p50')) for r in got]), 12, 2)}"
                f"{fmt(med([parse_duration_ms(r.get('p99')) for r in got]), 12, 2)}"
            )
        print()
    print("client columns are in microseconds; they are here so the pool's tail can be read")
    print("against the figure the client saw rather than on its own.")


if __name__ == "__main__":
    main()
