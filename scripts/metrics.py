"""Benchmark metrics shared by scripts/report.py (named cores) and scripts/sweep.py (design sweep),
so both compute every column the same way. Definitions: see reports/README.md.

Cycles come from LWC_TB's timing mode (`cycles` vector set): encryptions with a reused key,
first input word accepted to final status word.
"""
import csv
from pathlib import Path

SIZES = (16, 64, 1536)          # plaintext-only sizes, as in GMU's Table 12
LONG = (160, 1536)              # two sizes whose difference gives the long-message limit


def read_cycles(timing_csv):
    """{(ad_bytes, msg_bytes): cycles} for encryptions with a reused key."""
    cyc = {}
    with Path(timing_csv).open() as f:
        for r in csv.DictReader(f):
            if r["Operation"] == "AE" and r["New Key"] == "0":
                cyc.setdefault((int(r["AD Size"]), int(r["Msg Size"])), int(r["Actual Execution Time"]))
    return cyc


def f1(x):
    return f"{x:.1f}" if x is not None else ""


def cycle_cols(cyc):
    """Cycle-only columns, plus the raw steady-state cycles per block (pt, ad) for perf_cols."""
    lo, hi = LONG
    blk_pt = blk_ad = None   # cycles per 20-byte block in steady state
    if cyc.get((0, hi)) and cyc.get((0, lo)):
        blk_pt = (cyc[(0, hi)] - cyc[(0, lo)]) / ((hi - lo) / 20)
    if cyc.get((hi, 0)) and cyc.get((lo, 0)):
        blk_ad = (cyc[(hi, 0)] - cyc[(lo, 0)]) / ((hi - lo) / 20)
    cols = dict(cyc_blk_pt=f"{blk_pt:.2f}" if blk_pt else "", cyc_blk_ad=f"{blk_ad:.2f}" if blk_ad else "",
                **{f"cyc_pt_{n}": cyc.get((0, n)) or "" for n in SIZES})
    return cols, blk_pt, blk_ad


def perf_cols(cyc, blk_pt, blk_ad, fmax, luts):
    """Throughput (Mbit/s) and efficiency (Kbit/s per LUT) columns."""
    thr = {n: 8 * n * fmax / cyc[(0, n)] for n in SIZES if cyc.get((0, n))}
    long_pt = 160 * fmax / blk_pt if blk_pt else None
    long_ad = 160 * fmax / blk_ad if blk_ad else None
    return dict(thr_pt_long=f1(long_pt), thr_ad_long=f1(long_ad),
                ad_pt_ratio=f"{long_ad / long_pt:.2f}" if long_pt and long_ad else "",
                kbps_per_lut_pt=f1(long_pt * 1000 / luts if long_pt else None),
                kbps_per_lut_ad=f1(long_ad * 1000 / luts if long_ad else None),
                **{f"thr_pt_{n}": f1(t) for n, t in thr.items()},
                **{f"pct_long_{n}": f1(100 * t / long_pt) for n, t in thr.items() if long_pt})


SPEEDUPS = (("x_thr_pt_long", "thr_pt_long"), ("x_thr_pt_16", "thr_pt_16"),
            ("x_kbps_per_lut_pt", "kbps_per_lut_pt"))


def speedup_cols(row, base):
    """x_ columns: this row divided by the baseline row (both dicts of formatted strings)."""
    out = {}
    for col, src in SPEEDUPS:
        if row.get(src) and base and base.get(src):
            out[col] = f"{float(row[src]) / float(base[src]):.2f}"
    return out
