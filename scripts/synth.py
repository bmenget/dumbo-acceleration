#!/usr/bin/env python3
"""Find Fmax and area of the LWC top (wrapper + core) for one core.

Steps:
  1. take the core's compile-ordered file list (rtl/core_<core>/filelist.txt),
  2. run Vivado out-of-context synth + impl at a target clock period (scripts/vivado_build.tcl),
  3. read the worst setup slack (WNS) and retarget the clock: next = period - WNS (with a small
     push in the safe direction), until a run meets timing within 3% of the target, or --max-iter.
Fmax = 1000 / (period - WNS) MHz, taken from the fastest run that met timing.

Every iteration prints a line when it starts and when it finishes. Outputs:
  build/synth/<core>/p<period>/{vivado.log,timing.rpt,util.rpt,summary.txt}
  reports/synth_runs.csv      one row per Vivado run (appended)
  reports/synth_results.csv   one row per synthesis of a core (appended; `make report` uses the latest)

Usage (Vivado on PATH: `source ./setup.sh vivado`):
  python3 scripts/synth.py --core v2_opt1
"""
import argparse
import csv
import datetime
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import core_info  # noqa: E402

# Fixed for every design so results are comparable. Change deliberately, not per run.
PART = "xc7a100tftg256-2L"  # project target: XC7A100T-2FTG256L, the CW305 board's FPGA and the part used by
                             # GMU's LWC finalist benchmarking (ePrint 2023/484). See reports/README.md.
TOP = "LWC"                # wrapper + core; ports: clk, rst, pdi/sdi/do (32-bit)

RUNS_CSV = ROOT / "reports" / "synth_runs.csv"
RESULTS_CSV = ROOT / "reports" / "synth_results.csv"
RUN_COLS = ["date", "core", "rounds", "cycles_per_perm", "iter", "period_ns", "wns_ns", "fmax_est_mhz", "met",
            "luts", "ffs", "slices", "bram_tiles", "dsps", "runtime_s", "part", "vivado"]
RES_COLS = ["date", "core", "rounds", "cycles_per_perm", "closed", "best_period_ns", "wns_ns", "fmax_mhz", "luts", "ffs",
            "slices", "bram_tiles", "dsps", "runs", "part", "vivado"]


def say(msg):
    print(msg, flush=True)


def append_row(path, cols, row):
    path.parent.mkdir(parents=True, exist_ok=True)
    new = not path.exists()
    with path.open("a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        if new:
            w.writeheader()
        w.writerow({c: row.get(c, "") for c in cols})


def parse_util(path):
    """Pull the numbers we report out of Vivado's utilization report."""
    want = {"Slice LUTs": "luts", "Slice Registers": "ffs", "Slice": "slices",
            "Block RAM Tile": "bram_tiles", "DSPs": "dsps"}
    got = {}
    for line in Path(path).read_text().splitlines():
        m = re.match(r"^\|\s*([^|]+?)\s*\|\s*(\d+)\s*\|", line)
        if m:
            name = m.group(1).rstrip("*").strip()
            if name in want and want[name] not in got:
                got[want[name]] = int(m.group(2))
    missing = set(want.values()) - set(got)
    if missing:
        raise RuntimeError(f"could not find {sorted(missing)} in {path}")
    return got


def run_vivado(filelist, period, outdir):
    outdir.mkdir(parents=True, exist_ok=True)
    cmd = ["vivado", "-mode", "batch", "-nojournal", "-nolog",
           "-source", str(ROOT / "scripts" / "vivado_build.tcl"),
           "-tclargs", str(filelist), f"{period:.3f}", str(outdir), PART, TOP]
    with (outdir / "vivado.log").open("w") as log:
        rc = subprocess.run(cmd, cwd=outdir, stdout=log, stderr=subprocess.STDOUT).returncode
    summ = outdir / "summary.txt"
    if rc != 0 or not summ.exists():
        raise RuntimeError(f"Vivado failed (rc={rc}); see {outdir / 'vivado.log'}")
    kv = dict(l.split("=", 1) for l in summ.read_text().split())
    if kv["wns"] == "NA":
        raise RuntimeError(f"no timed paths found; see {outdir / 'timing.rpt'}")
    return float(kv["wns"]), kv["vivado"], parse_util(outdir / "util.rpt")


def synth_core(core, period0, max_iter):
    cfg = core
    rnd, cpp = core_info.rounds(core)
    flist = ROOT / "rtl" / f"core_{core}" / "filelist.txt"
    if not flist.exists():
        sys.exit(f"{flist} not found")
    work = ROOT / "build" / "synth" / cfg
    work.mkdir(parents=True, exist_ok=True)
    filelist = work / "filelist.txt"
    filelist.write_text("".join(f"{ROOT / rel}\n" for rel in flist.read_text().split()))

    say(f"\n=== core_{cfg}: part {PART}, top {TOP} ===")
    tried, runs, best = [], [], None
    period = period0
    for it in range(1, max_iter + 1):
        say(f"[{cfg}] iter {it}/{max_iter}: running Vivado at {period:.3f} ns "
            f"({1000 / period:.0f} MHz target) ...")
        t0 = time.time()
        wns, vver, util = run_vivado(filelist, period, work / f"p{period:.3f}")
        dt = time.time() - t0
        fmax_est = 1000.0 / (period - wns)
        met = wns >= 0
        row = dict(date=datetime.datetime.now().isoformat(timespec="seconds"), core=core,
                   rounds=rnd, cycles_per_perm=cpp, iter=it, period_ns=f"{period:.3f}", wns_ns=f"{wns:.3f}",
                   fmax_est_mhz=f"{fmax_est:.1f}", met=int(met), runtime_s=int(dt),
                   part=PART, vivado=vver, **util)
        append_row(RUNS_CSV, RUN_COLS, row)
        runs.append(row)
        tried.append(period)
        if met and (best is None or period < float(best["period_ns"])):
            best = row
        say(f"[{cfg}] iter {it}/{max_iter} done in {dt:.0f}s: WNS {wns:+.3f} ns "
            f"-> {'MET' if met else 'FAILED'}, Fmax ~{fmax_est:.1f} MHz, "
            f"LUT {util['luts']}, FF {util['ffs']}, slices {util['slices']}, "
            f"BRAM {util['bram_tiles']}, DSP {util['dsps']}")
        if met and wns <= 0.03 * period:
            say(f"[{cfg}] converged: met timing within 3% of the target")
            break
        # Retarget at the period the achieved delay implies, nudged to the safe side.
        nxt = max(period - wns * (0.95 if wns > 0 else 1.05), 1.0)
        if any(abs(nxt - p) < 0.01 for p in tried):
            say(f"[{cfg}] next target {nxt:.3f} ns already tried; stopping")
            break
        period = nxt

    final = best or runs[-1]
    fp, fw = float(final["period_ns"]), float(final["wns_ns"])
    res = dict(date=datetime.datetime.now().isoformat(timespec="seconds"), core=core,
               rounds=rnd, cycles_per_perm=cpp, closed=int(best is not None), best_period_ns=final["period_ns"],
               wns_ns=final["wns_ns"], fmax_mhz=f"{1000.0 / (fp - fw):.1f}", runs=len(runs),
               part=PART, vivado=final["vivado"],
               **{k: final[k] for k in ("luts", "ffs", "slices", "bram_tiles", "dsps")})
    append_row(RESULTS_CSV, RES_COLS, res)
    say(f"[{cfg}] RESULT: {'closed' if best else 'NOT closed (estimate from last run)'} "
        f"Fmax {res['fmax_mhz']} MHz at {final['period_ns']} ns | LUT {res['luts']} "
        f"FF {res['ffs']} slices {res['slices']} BRAM {res['bram_tiles']} DSP {res['dsps']}")
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--core", required=True, help="core name: rtl/core_<core>/ (e.g. v2, v2_opt1)")
    ap.add_argument("--period0", type=float, default=6.0, help="first clock target in ns")
    ap.add_argument("--max-iter", type=int, default=5)
    a = ap.parse_args()
    if not shutil.which("vivado"):
        sys.exit("vivado not on PATH. Run: source ./setup.sh vivado")
    synth_core(a.core, a.period0, a.max_iter)
    say(f"\nrows appended to {RESULTS_CSV.relative_to(ROOT)} and {RUNS_CSV.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
