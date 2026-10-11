#!/usr/bin/env python3
"""Turn a bench.sh run into a report.

`bench.sh` writes one row per measurement to `results.tsv`:

    arm  conc  rep  endpoint  label  rps  p50  p99

This reads that file and prints two tables — throughput and the warm/cold ratio —
because the ratio is what the repository is about and a table of raw rps buries
it. It also refuses to invent numbers: a cell with no successful repeat is printed
as `-`, never as a zero, since a zero reads as "measured, and it was terrible"
rather than "not measured".

Usage:
    python3 scripts/report.py [results.tsv]
"""

import statistics
import sys
from collections import defaultdict
from pathlib import Path

ARMS = {
    "P": ("stokehold", "worker", "warm", "pipe"),
    "T": ("stokehold", "spawn_cgi", "cold", "tcp"),
    "U": ("stokehold", "spawn_cgi", "cold", "unix"),
    "R": ("roadrunner", "worker", "warm", "pipe"),
    "F": ("nginx+php-fpm", "-", "cold", "unix"),
}


def load(path: Path):
    cells = defaultdict(list)
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 8:
            continue
        arm, conc, _rep, endpoint, _label, rps, p50, p99 = parts[:8]
        try:
            conc = int(conc)
        except ValueError:
            continue
        if rps == "FAIL":
            cells[(arm, endpoint, conc)]  # record the attempt, contribute no value
            continue
        try:
            cells[(arm, endpoint, conc)].append((float(rps), p50, p99))
        except ValueError:
            continue
    return cells


def median_or_dash(values):
    if not values:
        return None
    return statistics.median(v[0] for v in values)


def main():
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "results.tsv")
    if not path.exists():
        print(f"no {path} — run scripts/bench.sh first", file=sys.stderr)
        return 1

    cells = load(path)
    arms = sorted({k[0] for k in cells})
    endpoints = sorted({k[1] for k in cells})
    concs = sorted({k[2] for k in cells})

    print(f"# {path}\n")
    print("Models: " + "; ".join(
        f"**{a}** {ARMS[a][1]} ({ARMS[a][2]}, {ARMS[a][3]})" for a in arms if a in ARMS
    ) + "\n")

    for endpoint in endpoints:
        print(f"## `{endpoint}` — median rps\n")
        header = ["arm"] + [f"c={c}" for c in concs]
        print("| " + " | ".join(header) + " |")
        print("|" + "---|" * len(header))
        for arm in arms:
            row = [arm]
            for c in concs:
                med = median_or_dash(cells.get((arm, endpoint, c), []))
                row.append(f"{med:,.0f}" if med else "-")
            print("| " + " | ".join(row) + " |")
        print()

        # The ratio table: warm arms over cold arms, per concurrency.
        warm = [a for a in arms if a in ARMS and ARMS[a][2] == "warm"]
        cold = [a for a in arms if a in ARMS and ARMS[a][2] == "cold"]
        if warm and cold:
            print(f"`{endpoint}` — warm/cold ratio\n")
            header = ["warm \\ cold"] + cold
            print("| " + " | ".join(header) + " |")
            print("|" + "---|" * len(header))
            for w in warm:
                row = [w]
                for cd in cold:
                    ratios = []
                    for c in concs:
                        a = median_or_dash(cells.get((w, endpoint, c), []))
                        b = median_or_dash(cells.get((cd, endpoint, c), []))
                        if a and b:
                            ratios.append(a / b)
                    if ratios:
                        row.append(
                            f"{statistics.median(ratios):.2f}× "
                            f"[{' '.join(f'{r:.1f}' for r in ratios)}]"
                        )
                    else:
                        row.append("-")
                print("| " + " | ".join(row) + " |")
            print("  (median of the per-concurrency ratios; the bracketed list is")
            print("   each concurrency, so a ratio that only holds at one point is visible)\n")

    # T vs U is the transport comparison that holds the model equal.
    if {("T", e, c) for e in endpoints for c in concs} & set(cells):
        print("## T vs U — the transport, model held equal\n")
        for endpoint in endpoints:
            row = []
            for c in concs:
                t = median_or_dash(cells.get(("T", endpoint, c), []))
                u = median_or_dash(cells.get(("U", endpoint, c), []))
                row.append(f"c={c}: {u / t:.2f}×" if t and u else f"c={c}: -")
            print(f"  `{endpoint}` unix/tcp  " + "  ".join(row))
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
