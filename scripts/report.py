#!/usr/bin/env python3
"""Benchmark report: one row per v2 core, in the format of GMU's LWC benchmark tables
(Mohajerani et al., ePrint 2023/484, Tables 12 and 14), plus speedups against the baseline core_v2.

Inputs for each core:
  - measured cycles: build/sim/questa/<core>/cycles/timing.csv (`make cycles`). Encryptions with a
    reused key; cycles = first input word accepted to final status word.
  - Fmax, LUTs, FFs: the core's most recent row in reports/synth_results.csv (`make synth`).

Throughput (Mbit/s) = bits processed / (cycles / Fmax):
  thr_pt_<n>     plaintext-only messages (0 B AD) of n = 16, 64, 1536 bytes
  thr_pt_long    long-message limit: 8 * (1536 - 160) / (cycles(PT 1536) - cycles(PT 160)), i.e. the
                 steady-state cost per block with per-message overhead removed (the paper's "Long")
  thr_ad_long    the same for AD-only messages (0 B plaintext)
  cyc_blk_pt/ad  steady-state cycles per 20 bytes, from the same two sizes
Writes reports/benchmark.csv (rebuilt every run) and prints a table.

`checks` flags numbers you should not trust:
  cycles_failed  the cycles simulation did not pass
  cycles_stale   the core's RTL changed after the cycles run: re-run `make cycles`
  synth_stale    the core's RTL changed after its last synthesis: re-run `make synth`
  no_synth       never synthesized: cycle counts only
  other_part     the latest synthesis used a different FPGA than scripts/synth.py's PART: re-run `make synth`
  not_closed     no Vivado run met timing; Fmax is the estimate from the last run
"""
import csv
import datetime
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import core_info  # noqa: E402
import metrics  # noqa: E402
SIMS = ROOT / "build" / "sim" / "questa"
SYNTH = ROOT / "reports" / "synth_results.csv"
OUT = ROOT / "reports" / "benchmark.csv"
BASELINE = "v2"

COLS = ["core", "rounds", "cycles_per_perm", "fmax_mhz", "luts", "ffs",
        "thr_pt_long", "thr_pt_1536", "thr_pt_64", "thr_pt_16",
        "pct_long_1536", "pct_long_64", "pct_long_16",
        "thr_ad_long", "ad_pt_ratio",
        "kbps_per_lut_pt", "kbps_per_lut_ad",
        "x_thr_pt_long", "x_thr_pt_16", "x_kbps_per_lut_pt",
        "cyc_blk_pt", "cyc_blk_ad", "cyc_pt_16", "cyc_pt_64", "cyc_pt_1536",
        "part", "synth_date", "cycles_date", "checks"]


def current_part():
    m = re.search(r'^PART\s*=\s*"([^"]+)"', (ROOT / "scripts" / "synth.py").read_text(), re.M)
    return m.group(1)


def rtl_mtime(core):
    d = ROOT / "rtl" / f"core_{core}"
    files = [p for p in d.iterdir() if p.suffix in (".vhd", ".sv", ".v") or p.name == "defines.txt"]
    files += list((ROOT / "rtl" / "lwc").glob("*.vhd"))
    files += [ROOT / rel for rel in (d / "filelist.txt").read_text().split()]   # shared sources (rtl/logan/)
    return max(p.stat().st_mtime for p in files)


def measured_cycles(core):
    """{(ad, msg): cycles} for encryptions with a reused key, plus pass/fail and the run's time."""
    d = SIMS / core / "cycles"
    res = d / "result.txt"
    passed = res.exists() and res.read_text().strip() == "0"
    return metrics.read_cycles(d / "timing.csv"), passed, (d / "timing.csv").stat().st_mtime


def latest_synth():
    rows = {}
    if SYNTH.exists():
        for r in csv.DictReader(SYNTH.open()):
            rows[r["core"]] = r          # appended in time order: last row wins
    return rows


def core_row(core, s, part):
    cyc, passed, cdate = measured_cycles(core)
    mt = rtl_mtime(core)
    checks = []
    if not passed:
        checks.append("cycles_failed")
    if mt > cdate:
        checks.append("cycles_stale")
    if s is None:
        checks.append("no_synth")
    else:
        if mt > datetime.datetime.fromisoformat(s["date"]).timestamp():
            checks.append("synth_stale")
        if s.get("part") != part:
            checks.append("other_part")
        if s.get("closed") == "0":
            checks.append("not_closed")

    cols, blk_pt, blk_ad = metrics.cycle_cols(cyc)
    rnd, cpp = core_info.rounds(core)
    row = dict(core=core, rounds=rnd, cycles_per_perm=cpp, checks=" ".join(checks),
               cycles_date=datetime.datetime.fromtimestamp(cdate).isoformat(timespec="seconds"), **cols)
    if s is None:
        return row
    fmax = float(s["fmax_mhz"])
    luts = int(s["luts"])
    row.update(fmax_mhz=s["fmax_mhz"], luts=luts, ffs=s["ffs"], part=s.get("part", ""),
               synth_date=s["date"], **metrics.perf_cols(cyc, blk_pt, blk_ad, fmax, luts))
    return row


def main():
    part = current_part()
    synth = latest_synth()
    cores = sorted(p.parent.parent.name for p in SIMS.glob("v2*/cycles/timing.csv"))
    if BASELINE not in cores:
        raise SystemExit(f"no cycles for the baseline: run `make cycles CORE={BASELINE}` first")
    rows = [core_row(c, synth.get(c), part) for c in cores]
    rows.sort(key=lambda r: (r["core"] != BASELINE, r["rounds"] if r["rounds"] != "" else 999, r["core"]))

    base = next(r for r in rows if r["core"] == BASELINE)
    for r in rows:
        r.update(metrics.speedup_cols(r, base))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS)
        w.writeheader()
        for r in rows:
            w.writerow({c: r.get(c, "") for c in COLS})

    show = [("core", 10), ("rounds", 4), ("fmax_mhz", 7), ("luts", 6), ("ffs", 6), ("thr_pt_long", 9),
            ("thr_pt_1536", 9), ("thr_pt_64", 8), ("thr_pt_16", 8), ("thr_ad_long", 9),
            ("kbps_per_lut_pt", 10), ("cyc_blk_pt", 9), ("x_thr_pt_long", 7), ("x_kbps_per_lut_pt", 7)]
    heads = ["core", "R", "Fmax", "LUT", "FF", "PT long", "PT 1536", "PT 64", "PT 16", "AD long",
             "Kbps/LUT", "cyc/blk", "x thr", "x eff"]
    line = "".join(f"{h:>{w}}" if i else f"{h:<{w}}" for i, (h, (_, w)) in enumerate(zip(heads, show)))
    print(line + "  checks")
    print("-" * (len(line) + 8))
    for r in rows:
        print("".join(f"{str(r.get(c, '') or '-'):>{w}}" if i else f"{r[c]:<{w}}"
                      for i, (c, w) in enumerate(show)) + f"  {r['checks']}")
    print(f"\nthroughput in Mbit/s; x = relative to core_{BASELINE}; target part {part}; "
          f"written to {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
