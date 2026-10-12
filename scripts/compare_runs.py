#!/usr/bin/env python3
"""Compare two published sweeps, cell by cell and ratio by ratio.

`results/raw-841c963.tsv` is the sweep the report's tables were first built from;
`results/raw.tsv` is the current one. Keeping both is only useful if the difference can be
re-derived rather than believed, which is what this does.

    python3 scripts/compare_runs.py results/raw-841c963.tsv results/raw.tsv

The rps numbers are specific to one host, so the headline is not the throughput deltas —
it is the ratios, because warm-over-cold is a property of how much the application boots
rather than of the machine. A ratio that moved further than the run-to-run spread means
something changed; a throughput delta of the same size does not.

Exit status is 0 either way: this prints evidence, it does not pass or fail a run.
"""

import argparse
import collections
import statistics
from pathlib import Path


def load(path):
    """`arm, conc, rep, endpoint, label, rps, p50, p99` -> {(arm, conc, endpoint): [rps]}."""
    cells = collections.defaultdict(list)
    for line in Path(path).read_text().splitlines():
        parts = line.split("\t")
        if len(parts) < 6:
            continue
        try:
            cells[(parts[0], int(parts[1]), parts[3])].append(float(parts[5]))
        except ValueError:
            continue
    return cells


def median(cells, key):
    series = cells.get(key)
    return statistics.median(series) if series else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before")
    parser.add_argument("after")
    parser.add_argument("--conc", default="1,4,8,16,32")
    args = parser.parse_args()

    concs = [int(c) for c in args.conc.split(",")]
    before = load(args.before)
    after = load(args.after)

    print(f"before: {args.before}")
    print(f"after:  {args.after}")

    print("\nthroughput, median rps")
    header = f"{'arm':<4}{'endpoint':<10}" + "".join(f"{'c=' + str(c):>14}" for c in concs)
    print(header)
    print("-" * len(header))

    deltas = []
    for endpoint in ["/", "/items"]:
        for arm in "PRFUT":
            row = f"{arm:<4}{endpoint:<10}"
            for conc in concs:
                old = median(before, (arm, conc, endpoint))
                new = median(after, (arm, conc, endpoint))
                if old is None or new is None:
                    row += f"{'-':>14}"
                    continue
                delta = (new - old) / old * 100
                deltas.append(abs(delta))
                row += f"{new:>8.0f}{delta:>+5.1f}%"
            print(row)
        print()

    if deltas:
        print(f"median |delta| across {len(deltas)} cells: {statistics.median(deltas):.1f}%")

    # The ratios are the point. A pair of arms measured in the same run is immune to the
    # host drifting underneath it, so these are more trustworthy than either table above.
    print("\nheadline ratios (warm-over-cold, or the transport pair), at each concurrency")
    ratio_header = f"{'ratio':<20}{'endpoint':<10}" + "".join(f"{'c=' + str(c):>14}" for c in concs)
    print(ratio_header)
    print("-" * len(ratio_header))

    # Warm over cold, so a larger number means the resident model is further ahead — the
    # direction the report quotes (P/F 2.11x, not 0.47x).
    pairs = [("P", "F", "P/F warm/cold"), ("R", "F", "R/F warm/cold"), ("T", "U", "T/U transport")]
    for endpoint in ["/", "/items"]:
        for numerator, denominator, label in pairs:
            row = f"{label:<20}{endpoint:<10}"
            for conc in concs:
                old_n = median(before, (numerator, conc, endpoint))
                old_d = median(before, (denominator, conc, endpoint))
                new_n = median(after, (numerator, conc, endpoint))
                new_d = median(after, (denominator, conc, endpoint))
                if None in (old_n, old_d, new_n, new_d) or old_d == 0 or new_d == 0:
                    row += f"{'-':>14}"
                    continue
                row += f"{new_n / new_d:>8.2f}x{(new_n / new_d - old_n / old_d) / (old_n / old_d) * 100:>+5.1f}%"
            print(row)
        print()


if __name__ == "__main__":
    main()
