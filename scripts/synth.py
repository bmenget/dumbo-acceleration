#!/usr/bin/env python3
"""Find Fmax and area of the LWC top (wrapper + core) for one core.

Steps:
  1. take the core's compile-ordered file list (rtl/core_<core>/filelist.txt),
  2. run Vivado out-of-context synth + impl at a target clock period (scripts/vivado_build.tcl),
  3. search for Fmax with scripts/fmax.py: a tight probe target predicted from the rounds per cycle,
     then retargets with calibrated headroom until a met run is bracketed by a tighter failed one
     (see fmax.py for the rule and its calibration on reports/synth_runs.csv).
Fmax = 1000 / (period - WNS) MHz from the met run with the smallest achieved delay.

Every iteration prints a line when it starts and when it finishes. Outputs:
  build/synth/<core>/p<period>/{vivado.log,timing.rpt,util.rpt,summary.txt}
  reports/synth_runs.csv      one row per Vivado run (appended)
  reports/synth_results.csv   one row per synthesis of a core (appended; `make report` uses the latest)

--flow tsyn|perf|area runs the same search with another Vivado flow (see scripts/vivado_build.tcl): timing-driven
synthesis, plus timing or area directives. Those runs go to build/synth/<core>/<flow>/p<period>/ and to
reports/flow_runs.csv / reports/flow_results.csv (same columns plus `flow`), so the standard results that
`make report` uses all come from one flow ("base").

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
import fmax  # noqa: E402

# Fixed for every design so results are comparable. Change deliberately, not per run.
PART = "xc7a100tftg256-2L"  # project target: XC7A100T-2FTG256L, the CW305 board's FPGA and the part used by
                             # GMU's LWC finalist benchmarking (ePrint 2023/484). See reports/README.md.
TOP = "LWC"                # wrapper + core; ports: clk, rst, pdi/sdi/do (32-bit)

RUNS_CSV = ROOT / "reports" / "synth_runs.csv"
RESULTS_CSV = ROOT / "reports" / "synth_results.csv"
FLOW_RUNS_CSV = ROOT / "reports" / "flow_runs.csv"
FLOW_RESULTS_CSV = ROOT / "reports" / "flow_results.csv"
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
        m = re.match(r"^\|\s*([^|]+?)\s*\|\s*(\d+(?:\.\d+)?)\s*\|", line)
        if m:
            name = m.group(1).rstrip("*").strip()
            if name in want and want[name] not in got:
                v = float(m.group(2))          # Block RAM tiles can be fractional (RAMB18 = 0.5)
                got[want[name]] = int(v) if v.is_integer() else v
    missing = set(want.values()) - set(got)
    if missing:
        raise RuntimeError(f"could not find {sorted(missing)} in {path}")
    return got


def run_vivado(filelist, period, outdir, timeout=None, flow="base"):
    """One Vivado run; timeout (s) kills it (raises RuntimeError)."""
    outdir.mkdir(parents=True, exist_ok=True)
    cmd = ["vivado", "-mode", "batch", "-nojournal", "-nolog",
           "-source", str(ROOT / "scripts" / "vivado_build.tcl"),
           "-tclargs", str(filelist), f"{period:.3f}", str(outdir), PART, TOP, flow]
    with (outdir / "vivado.log").open("w") as log:
        try:
            rc = subprocess.run(cmd, cwd=outdir, stdout=log, stderr=subprocess.STDOUT, timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"Vivado timed out after {timeout / 3600:.1f} h; see {outdir / 'vivado.log'}")
    summ = outdir / "summary.txt"
    if rc != 0 or not summ.exists():
        raise RuntimeError(f"Vivado failed (rc={rc}); see {outdir / 'vivado.log'}")
    kv = dict(l.split("=", 1) for l in summ.read_text().split())
    if kv["wns"] == "NA":
        raise RuntimeError(f"no timed paths found; see {outdir / 'timing.rpt'}")
    return float(kv["wns"]), kv["vivado"], parse_util(outdir / "util.rpt")


def synth_core(core, period0, max_iter, flow="base"):
    cfg = core if flow == "base" else f"{core}:{flow}"
    runs_csv, res_csv = (RUNS_CSV, RESULTS_CSV) if flow == "base" else (FLOW_RUNS_CSV, FLOW_RESULTS_CSV)
    run_cols, res_cols = (RUN_COLS, RES_COLS) if flow == "base" else (RUN_COLS + ["flow"], RES_COLS + ["flow"])
    extra = {} if flow == "base" else {"flow": flow}
    rnd, cpp = core_info.rounds(core)
    flist = ROOT / "rtl" / f"core_{core}" / "filelist.txt"
    if not flist.exists():
        sys.exit(f"{flist} not found")
    base = ROOT / "build" / "synth" / core
    work = base if flow == "base" else base / flow
    work.mkdir(parents=True, exist_ok=True)
    filelist = base / "filelist.txt"
    filelist.write_text("".join(f"{ROOT / rel}\n" for rel in flist.read_text().split()))
    # Verilog defines (Logan's cores): vivado_build.tcl reads defines.txt next to the file list.
    defs = flist.parent / "defines.txt"
    staged = base / "defines.txt"
    if defs.exists():
        shutil.copyfile(defs, staged)
    elif staged.exists():
        staged.unlink()

    say(f"\n=== core_{cfg}: part {PART}, top {TOP} ===")
    if period0 is None:
        period0 = fmax.probe_period(rnd, core_info.slots(core)) if rnd != "" else 6.0

    def run(period):
        say(f"[{cfg}] Vivado at {period:.3f} ns ({1000 / period:.0f} MHz target) ...")
        t0 = time.time()
        wns, vver, util = run_vivado(filelist, period, work / f"p{period:.3f}", flow=flow)
        return dict(wns=wns, vivado=vver, util=util, dt=time.time() - t0)

    def log(r):
        row = dict(date=datetime.datetime.now().isoformat(timespec="seconds"), core=core,
                   rounds=rnd, cycles_per_perm=cpp, iter=r["iter"], period_ns=f"{r['period']:.3f}",
                   wns_ns=f"{r['wns']:.3f}", fmax_est_mhz=f"{1000.0 / r['achieved']:.1f}", met=int(r["met"]),
                   runtime_s=int(r["dt"]), part=PART, vivado=r["vivado"], **r["util"], **extra)
        append_row(runs_csv, run_cols, row)
        u = r["util"]
        say(f"[{cfg}] run {r['iter']} done in {r['dt']:.0f}s: WNS {r['wns']:+.3f} ns "
            f"-> {'MET' if r['met'] else 'FAILED'}, achieved {r['achieved']:.3f} ns ({1000.0 / r['achieved']:.1f} MHz), "
            f"LUT {u['luts']}, FF {u['ffs']}, slices {u['slices']}, BRAM {u['bram_tiles']}, DSP {u['dsps']}")

    runs, res = fmax.search(run, period0, max_iter, log)
    best = res["run"]
    out = dict(date=datetime.datetime.now().isoformat(timespec="seconds"), core=core,
               rounds=rnd, cycles_per_perm=cpp, closed=res["closed"], best_period_ns=f"{best['period']:.3f}",
               wns_ns=f"{best['wns']:.3f}", fmax_mhz=f"{res['fmax_mhz']:.1f}", runs=len(runs),
               part=PART, vivado=best["vivado"], **best["util"], **extra)
    append_row(res_csv, res_cols, out)
    say(f"[{cfg}] RESULT: {'closed' if res['closed'] else 'NOT closed (estimate: best achieved delay)'} "
        f"Fmax {out['fmax_mhz']} MHz at {out['best_period_ns']} ns after {len(runs)} runs | LUT {out['luts']} "
        f"FF {out['ffs']} slices {out['slices']} BRAM {out['bram_tiles']} DSP {out['dsps']}")
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--core", required=True, help="core name: rtl/core_<core>/ (e.g. v2, v2_opt1)")
    ap.add_argument("--period0", type=float, default=None,
                    help="first clock target in ns (default: fmax.py's probe predicted from the rounds per cycle)")
    ap.add_argument("--max-iter", type=int, default=fmax.MAX_RUNS, help="Vivado runs at most")
    ap.add_argument("--flow", default="base", choices=["base", "tsyn", "perf", "area"],
                    help="Vivado flow (default base, the project standard; others log to reports/flow_*.csv)")
    a = ap.parse_args()
    if not shutil.which("vivado"):
        sys.exit("vivado not on PATH. Run: source ./setup.sh vivado")
    synth_core(a.core, a.period0, a.max_iter, a.flow)
    r, u = (RESULTS_CSV, RUNS_CSV) if a.flow == "base" else (FLOW_RESULTS_CSV, FLOW_RUNS_CSV)
    say(f"\nrows appended to {r.relative_to(ROOT)} and {u.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
