#!/usr/bin/env python3
"""
WP-12 benchmark analysis — computes medians / means / 95% CI per
(cell, backend) from the shared CSV schema and produces the §12.7 gate
verdict.

Usage:
  python3 analyze_wp12.py Measurements/wp12/bench-<timestamp>.csv

CSV schema (shared by the Swift bench and the harness bench-hash):
  run,cell,backend,wall_s,cpu_s,peak_rss_mb,thermal_before,thermal_after,
  cpu_speed_limit,gpu_wall_s,fallbacks,staged_bytes,throughput_mib_s

Thermal semantics: Swift rows carry ProcessInfo.thermalState (0 = nominal),
harness rows carry the pmset CPU_Speed_Limit percent (100 = no limit
recorded). Both "0" and "100" count as "no thermal throttling observed".

Gate items (§12.7, read from TORRENTINO_NATIVE_MACOS_IMPLEMENTATION_PLAN.md
L1471+):
  G1  bit-for-bit known vectors                      -> test_wp12_01 (not here)
  G2  v1/v2/hybrid vs CPU reference 100%             -> test_wp12_01 (not here)
  G3  >=100 randomized cases                         -> test_wp12_01 (not here)
  G4  >=1000 stress iterations                       -> test_wp12_01 (not here)
  G5  independent BEP validator                      -> test_wp12_04 (not here)
  G6  >=20% median wall-clock gain (Metal vs CPU) on eligible workloads >=4 GiB
  G7  p95 regression <= 5% where Automatic picks Metal below break-even
  G8  memory budget (peak RSS within an order of magnitude of CPU)
  G9  throughput-per-joule (CPU-seconds proxy) not worse, or documented gain
  G10 no new serious/critical thermal events
  G11 fallbacks == 0 on healthy hardware            -> test_wp12_03 (not here)
"""
import collections
import csv
import math
import statistics
import sys

T95 = 2.2622  # t_{0.975} for n = 10 (9 df); conservative for smaller n


def ci95(values):
    n = len(values)
    if n < 2:
        return (float("nan"), float("nan"))
    mean = statistics.mean(values)
    sd = statistics.stdev(values)
    half = T95 * sd / math.sqrt(n)
    return (mean - half, mean + half)


def p95(values):
    sorted_v = sorted(values)
    return sorted_v[int(math.ceil(0.95 * len(sorted_v))) - 1]


def thermal_ok(row):
    return row["tb"] in ("0", "100") and row["ta"] in ("0", "100")


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    path = sys.argv[1]

    cells = collections.defaultdict(list)  # (cell, backend) -> rows
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            if not row["cell"]:
                continue
            cells[(row["cell"], row["backend"])].append(
                {
                    "wall": float(row["wall_s"]),
                    "cpu": float(row["cpu_s"]),
                    "rss": float(row["peak_rss_mb"]),
                    "tb": row["thermal_before"],
                    "ta": row["thermal_after"],
                    "fb": int(row["fallbacks"]),
                }
            )

    print(f"# WP-12 benchmark analysis — {path}\n")

    table = []
    for (cell, backend), rows in sorted(cells.items()):
        walls = [r["wall"] for r in rows]
        med = statistics.median(walls)
        lo, hi = ci95(walls)
        p95v = p95(walls)
        cpu_med = statistics.median(r["cpu"] for r in rows)
        rss_med = statistics.median(r["rss"] for r in rows)
        fb = sum(r["fb"] for r in rows)
        therm = all(thermal_ok(r) for r in rows)
        table.append((cell, backend, med, lo, hi, p95v, cpu_med, rss_med, fb, therm))

    print("| cell | backend | median wall (s) | 95% CI | p95 | median cpu-s | median RSS (MB) | fb | thermal |")
    print("|---|---|---|---|---|---|---|---|---|")
    for cell, backend, med, lo, hi, p95v, cpu_med, rss_med, fb, therm in table:
        print(
            f"| {cell} | {backend} | {med:.4f} | {lo:.4f}–{hi:.4f} | {p95v:.4f} | "
            f"{cpu_med:.4f} | {rss_med:.1f} | {fb} | {'ok' if therm else 'FAIL'} |"
        )
    print()

    verdicts = []
    by_cell = collections.defaultdict(dict)
    for cell, backend, med, lo, hi, p95v, cpu_med, rss_med, fb, therm in table:
        by_cell[cell][backend] = (med, p95v, cpu_med, rss_med, fb, therm)

    for cell in sorted(by_cell):
        c = by_cell[cell]
        if "cpu" not in c or "metal" not in c:
            continue
        speedup = c["cpu"][0] / c["metal"][0]
        rss_ratio = c["metal"][3] / c["cpu"][3] if c["cpu"][3] > 0 else float("inf")
        per_mib = {b: c[b][2] * 1e6 / (1024 * 1024) for b in ("cpu", "metal")}  # cpu-s per MiB
        corpus_tag = cell.split("/")[0]
        is_gib = corpus_tag.endswith("g")
        corpus_mib = int(corpus_tag[:-1]) * 1024 if is_gib else int(corpus_tag[:-1])
        big = corpus_mib >= 4096  # §12.7 eligibility line: >= 4 GiB
        if big:
            verdicts.append(
                ("G6", "PASS" if speedup >= 1.20 else "FAIL",
                 f"{cell}: Metal {c['metal'][0]:.4f}s vs CPU {c['cpu'][0]:.4f}s = {speedup:.2f}x "
                 f"(>=1.20 required on >=4 GiB workloads)"))
        else:
            verdicts.append(
                ("G6", "below-threshold",
                 f"{cell}: {speedup:.2f}x at {cell} (<4 GiB eligibility line; informational)"))
        p95_ratio = c["cpu"][1] / c["metal"][1]
        if not big:
            verdicts.append(
                ("G7", "below-threshold",
                 f"{cell}: p95 ratio CPU/Metal = {p95_ratio:.3f} (informational)"))
            verdicts.append(
                ("G8", "below-threshold",
                 f"{cell}: Metal/CPU peak RSS ratio = {rss_ratio:.2f} (informational)"))
            verdicts.append(
                ("G9", "below-threshold",
                 f"{cell}: Metal cpu-s/MiB {per_mib['metal']:.4f} vs CPU {per_mib['cpu']:.4f} "
                 f"(informational)"))
            verdicts.append(
                ("G10", "PASS" if c["cpu"][5] and c["metal"][5] else "FAIL",
                 f"{cell}: thermal evidence OK (no throttling observed)"))
            continue
        verdicts.append(
            ("G7", "PASS" if p95_ratio >= 0.95 else "FAIL",
             f"{cell}: p95 ratio CPU/Metal = {p95_ratio:.3f} (>=0.95 required)"))
        verdicts.append(
            ("G8", "PASS" if rss_ratio < 10 else "FAIL",
             f"{cell}: Metal/CPU peak RSS ratio = {rss_ratio:.2f} (<10 required)"))
        verdicts.append(
            ("G9", "PASS" if per_mib["metal"] <= per_mib["cpu"] * 1.05 else "FAIL",
             f"{cell}: Metal cpu-s/MiB {per_mib['metal']:.4f} vs CPU {per_mib['cpu']:.4f}"))
        verdicts.append(
            ("G10", "PASS" if c["cpu"][5] and c["metal"][5] else "FAIL",
             f"{cell}: thermal evidence OK (no throttling observed)"))

    print("## §12.7 gate verdicts (measured on this machine)\n")
    print("| gate | verdict | evidence |")
    print("|---|---|---|")
    for gate, verdict, note in verdicts:
        print(f"| {gate} | {verdict} | {note} |")
    print()
    print("Gates G1–G5, G11 are covered by test_wp12_01/03/04 (QA scripts). "
          "G6 is measured only where a >=4 GiB workload fit on this disk; "
          "if every cell is below the eligibility line the plan's decision "
          "rule cannot be satisfied and the outcome is REJECT_METAL (with "
          "measured evidence, not N/A).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
