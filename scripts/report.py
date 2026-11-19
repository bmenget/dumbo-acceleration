#!/usr/bin/env python3
"""Benchmark report: every v2 core against the baseline core_v2.

For each core with measured cycles (`make cycles CORE=<core>` ->
build/sim/questa/<core>/cycles/timing.csv), take:
  - cycles per workload: encryption, key reused (the steady-state case), from the testbench's measured
    "Actual Execution Time" (first input word accepted to final status word),
  - Fmax and LUTs from that core's most recent row in reports/synth_results.csv (`make synth`),
and compute latency, throughput (AD + message bytes per second), throughput per kLUT, and speedups
against core_v2. Writes reports/benchmark.csv (regenerated every run) and prints a table.

Flags in the `checks` column:
  cycles_failed   the cycles simulation did not pass: its cycle counts are meaningless
  cycles_stale    the core's RTL changed after the cycles run: re-run `make cycles`
  synth_stale     the core's RTL changed after its last synthesis: re-run `make synth`
  no_synth        never synthesized: no Fmax, so no throughput
  dirty           the synthesized RTL had uncommitted changes (commit column ends in +dirty)
"""
import csv
import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SIMS = ROOT / "build" / "sim" / "questa"
SYNTH = ROOT / "reports" / "synth_results.csv"
OUT = ROOT / "reports" / "benchmark.csv"
BASELINE = "v2"

# (name, AD bytes, message bytes)
WORKLOADS = [
    ("short_16+16", 16, 16),       # NIST LWC benchmark point: per-message overhead dominates
    ("short_64+64", 64, 64),
    ("long_1536+1536", 1536, 1536),  # long messages: steady-state cost per block
    ("msg_0+1536", 0, 1536),
    ("ad_1536+0", 1536, 0),
]
COLS = ["core", "workload", "ad_bytes", "msg_bytes", "cycles", "fmax_mhz", "luts", "latency_us",
        "throughput_mbps", "mbps_per_klut", "speedup_cycles", "speedup_throughput", "speedup_mbps_per_klut",
        "synth_commit", "synth_date", "cycles_date", "checks"]


def rtl_mtime(core):
    files = [p for p in (ROOT / "rtl" / f"core_{core}").iterdir() if p.suffix == ".vhd"]
    files += list((ROOT / "rtl" / "lwc").glob("*.vhd"))
    return max(p.stat().st_mtime for p in files)


def measured_cycles(core):
    """{(ad, msg): cycles} for encryptions with a reused key, plus the run's status and date."""
    d = SIMS / core / "cycles"
    res = d / "result.txt"
    passed = res.exists() and res.read_text().strip() == "0"
    cyc = {}
    for r in csv.DictReader((d / "timing.csv").open()):
        if r["Operation"] == "AE" and r["New Key"] == "0":
            cyc.setdefault((int(r["AD Size"]), int(r["Msg Size"])), int(r["Actual Execution Time"]))
    return cyc, passed, (d / "timing.csv").stat().st_mtime


def latest_synth():
    if not SYNTH.exists():
        return {}
    rows = {}
    for r in csv.DictReader(SYNTH.open()):
        if r.get("core"):
            rows[r["core"]] = r          # file is appended in time order: last row wins
    return rows


def main():
    synth = latest_synth()
    cores = sorted(p.parent.parent.name for p in SIMS.glob("v2*/cycles/timing.csv"))
    if BASELINE not in cores:
        raise SystemExit(f"no cycles for the baseline: run `make cycles CORE={BASELINE}` first")
    rows = []
    for core in cores:
        cyc, passed, cdate = measured_cycles(core)
        s = synth.get(core)
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
            if s.get("commit", "").endswith("+dirty"):
                checks.append("dirty")
        for name, ad, msg in WORKLOADS:
            c = cyc.get((ad, msg))
            if c is None:
                continue
            row = dict(core=core, workload=name, ad_bytes=ad, msg_bytes=msg, cycles=c,
                       cycles_date=datetime.datetime.fromtimestamp(cdate).isoformat(timespec="seconds"),
                       checks=" ".join(checks))
            if s is not None:
                fmax, luts = float(s["fmax_mhz"]), int(s["luts"])
                t_us = c / fmax
                tput = 8 * (ad + msg) / t_us
                row.update(fmax_mhz=s["fmax_mhz"], luts=luts, latency_us=f"{t_us:.3f}",
                           throughput_mbps=f"{tput:.1f}", mbps_per_klut=f"{tput / (luts / 1000):.1f}",
                           synth_commit=s.get("commit", ""), synth_date=s["date"])
            rows.append(row)

    base = {r["workload"]: r for r in rows if r["core"] == BASELINE}
    for r in rows:
        b = base.get(r["workload"])
        if not b:
            continue
        r["speedup_cycles"] = f"{b['cycles'] / r['cycles']:.2f}"
        if r.get("throughput_mbps") and b.get("throughput_mbps"):
            r["speedup_throughput"] = f"{float(r['throughput_mbps']) / float(b['throughput_mbps']):.2f}"
            r["speedup_mbps_per_klut"] = f"{float(r['mbps_per_klut']) / float(b['mbps_per_klut']):.2f}"

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS)
        w.writeheader()
        for r in rows:
            w.writerow({c: r.get(c, "") for c in COLS})

    hdr = (f"{'core':<10}{'workload':<17}{'cycles':>8}{'Fmax':>8}{'LUT':>7}{'Mbps':>9}{'Mbps/kLUT':>11}"
           f"{'x cyc':>7}{'x Mbps':>8}{'x eff':>7}  checks")
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        print(f"{r['core']:<10}{r['workload']:<17}{r['cycles']:>8}{r.get('fmax_mhz', '-'):>8}"
              f"{str(r.get('luts', '-')):>7}{r.get('throughput_mbps', '-'):>9}{r.get('mbps_per_klut', '-'):>11}"
              f"{r.get('speedup_cycles', '-'):>7}{r.get('speedup_throughput', '-'):>8}"
              f"{r.get('speedup_mbps_per_klut', '-'):>7}  {r['checks']}")
    print(f"\nspeedups (x) are relative to core_{BASELINE}; written to {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
