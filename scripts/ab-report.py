#!/usr/bin/env python3
"""Read an `ab-perf.sh` run and report the within-round ratios.

Why this is not `compare_runs.py`
---------------------------------
`compare_runs.py` compares two *published sweeps*: two files, one arm per block,
each arm measured once per cell. That is the right tool for "did the sweep move",
and the wrong one here, because the whole point of `ab-perf.sh` is that every
variant was measured *inside the same round* and the starting order rotated. The
estimator that uses that structure is a per-round ratio, and the spread of those
ratios across rounds is the error bar — not the difference between two medians,
which throws the pairing away and re-imports whatever the host did between blocks.

So the headline here is:

    for each round r:   ratio_r = rps(new-req, r) / rps(rr, r)
    published:          median over r, with min and max

`rr` is the denominator because it is the control: it shares no code with any
other variant, so a ratio that moves while `rr`'s own absolute rps did not is a
change in volucer, and a round in which every variant moved together is the
host. That is the distinction `bench.sh`'s blocked layout cannot make.

    python3 scripts/ab-report.py ~/volucer-bench-run-ab/ab-rps.tsv


Exit status is 0 either way. This prints evidence; it does not pass or fail a run.
"""

import argparse
import collections
import statistics
from pathlib import Path

CONC_ORDER = ["1", "4", "8", "16", "32"]


def load(path):
    """`variant, conc, round, endpoint, label, rps, p50, p99` -> nested dict."""
    rows = collections.defaultdict(dict)  # (endpoint, conc, variant) -> {round: rps}
    labels = {}
    for line in Path(path).read_text().splitlines():
        parts = line.split("\t")
        if len(parts) < 6 or parts[0] == "variant":
            continue
        variant, conc, rnd, endpoint, label, rps = parts[:6]
        if rps == "FAIL":
            continue
        try:
            rows[(endpoint, conc, variant)][rnd] = float(rps)
        except ValueError:
            continue
        labels[variant] = label
    return rows, labels


def med(values):
    return statistics.median(values) if values else None


def fmt(value, width=9, places=0):
    return f"{value:>{width}.{places}f}" if value is not None else f"{'-':>{width}}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tsv", help="ab-rps.tsv from ab-perf.sh")
    parser.add_argument(
        "--numerator",
        default="new-req",
        help="variant the headline ratio is computed for (default: new-req)",
    )
    parser.add_argument(
        "--control",
        default="rr",
        help="the control arm the ratio divides by (default: rr)",
    )
    args = parser.parse_args()

    rows, labels = load(args.tsv)
    if not rows:
        raise SystemExit(f"no measured rows in {args.tsv}")

    endpoints = sorted({k[0] for k in rows}, key=lambda e: (e != "/", e))
    concs = sorted({k[1] for k in rows}, key=lambda c: (CONC_ORDER.index(c) if c in CONC_ORDER else 99, c))
    variants = []
    for k in rows:
        if k[2] not in variants:
            variants.append(k[2])
    rounds = sorted({r for v in rows.values() for r in v}, key=lambda r: int(r))

    print(f"file:     {args.tsv}")
    print(f"variants: {', '.join(variants)}")
    print(f"rounds:   {', '.join(rounds)}")
    print()

    # --- absolute rps, which is NOT comparable across runs but shows the shape ---
    print("absolute median rps")
    header = f"{'variant':<10}{'endpoint':<10}" + "".join(f"{'c=' + c:>10}" for c in concs)
    print(header)
    print("-" * len(header))
    for variant in variants:
        for endpoint in endpoints:
            row = f"{variant:<10}{endpoint:<10}"
            for conc in concs:
                row += fmt(med(list(rows.get((endpoint, conc, variant), {}).values())))
            print(row)
    print()

    # --- the estimator: a ratio computed inside each round, then summarised ------
    print(f"within-round ratios vs {args.control} (the control arm)")
    print("each cell: median over rounds [min..max]   ->  a spread that spans 1.00 is no evidence")
    header = f"{'numerator':<10}{'endpoint':<10}" + "".join(f"{'c=' + c:>26}" for c in concs)
    print(header)
    print("-" * len(header))
    for variant in variants:
        if variant == args.control:
            continue
        for endpoint in endpoints:
            row = f"{variant:<10}{endpoint:<10}"
            for conc in concs:
                ratios = []
                for rnd in rounds:
                    n = rows.get((endpoint, conc, variant), {}).get(rnd)
                    d = rows.get((endpoint, conc, args.control), {}).get(rnd)
                    if n is not None and d:
                        ratios.append(n / d)
                if not ratios:
                    row += f"{'-':>26}"
                    continue
                m = statistics.median(ratios)
                row += f"{m:>17.3f}x [{min(ratios):.3f}..{max(ratios):.3f}]"
            print(row)
        print()

    # --- the two questions, stated as ratios of ratios ---------------------------
    print("the two questions, as ratios of ratios (median over rounds and cells)")
    print()
    for endpoint in endpoints:
        for conc in concs:
            def per_round(a, b):
                out = []
                for rnd in rounds:
                    x = rows.get((endpoint, conc, a), {}).get(rnd)
                    y = rows.get((endpoint, conc, b), {}).get(rnd)
                    if x is not None and y:
                        out.append(x / y)
                return out

            opt_vs_req = per_round("new-opt", "new-req")
            new_vs_old = per_round("new-req", "old-req")
            lead_vs_rr = per_round("new-req", "rr")
            old_vs_rr = per_round("old-req", "rr")
            # The embedded runtime, against both warm servers. `franken` is not part
            # of the volucer story at all — it is the one arm that answers "what
            # does embedding buy you", so it is reported as its own pair of ratios
            # rather than folded into the checksum question above. Both denominators
            # are controls that share no code with it.
            franken_vs_rr = per_round("franken", "rr")
            franken_vs_req = per_round("franken", "new-req")
            print(f"  {endpoint:<7} c={conc:<3}")
            for label, series in [
                ("skipping the checksum (new-opt / new-req)", opt_vs_req),
                ("the crc32c fix       (new-req / old-req)", new_vs_old),
                ("the lead over rr     (new-req / rr)      ", lead_vs_rr),
                ("what the fix bought  (old-req / rr)      ", old_vs_rr),
                ("frankenphp vs rr     (franken / rr)      ", franken_vs_rr),
                ("frankenphp vs volucer  (franken / new-req) ", franken_vs_req),
            ]:
                if not series:
                    continue
                m = statistics.median(series)
                verdict = ""
                if min(series) > 1.0:
                    verdict = "  <- every round the same way"
                elif max(series) < 1.0:
                    verdict = "  <- every round the same way (down)"
                print(
                    f"    {label}  {m:>7.3f}x  "
                    f"({(m - 1) * 100:+6.1f}%)  "
                    f"[{min(series):.3f}..{max(series):.3f}]  n={len(series)}{verdict}"
                )
            print()


if __name__ == "__main__":
    main()
