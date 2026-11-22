#!/usr/bin/env python3
"""Design-space sweep of the parameterized core rtl/core_v2_gen/ (see rtl/core_v2_gen/GEN.md).

For every point (R rounds per unit, S pipeline stages per unit, U units, fast loader on/off):
  1. write the core into a temporary folder: rtl/core_v2_gen/*.vhd with the four G_* constants set,
  2. compile with Questa and run two LWC_TB sets: `edge` (block-boundary lengths, enc + dec) and `cycles`
     (timing mode; also checks every output and includes 1536 B messages, so multi-batch scheduling is
     exercised). Either failing stops the point,
  3. Vivado: out-of-context synth + implementation (scripts/vivado_build.tcl), Fmax search by
     scripts/fmax.py (tight probe predicted from R/S and N, then calibrated retargets; --max-iter caps it),
  4. classify the critical path of the best run (scripts/critpath.py),
  5. append one row to reports/sweep/sweep.csv (and one per Vivado run to reports/sweep/sweep_runs.csv),
  6. clean up: the point's folder replaces build/sweep/last/ (the only build kept), or moves to
     build/sweep/failed/<point>/ if validation or synthesis failed. The compiled Questa library is
     deleted in both cases; RTL, logs and reports stay.
Points with S not dividing R are skipped (unequal stages), and so are points over the size limits: --max-n
(calls in flight) and --max-luts (estimated LUTs, default 75% of the device; estimate in luts_estimate()).
Points already in sweep.csv with the same tag, configuration and RTL hash are skipped too (resume), unless
--force.
Interrupted runs: a point's row is written only when it finishes, so rerunning the same command redoes only
the points that were in progress (their leftover folders in build/sweep/work/ are removed at startup).
RTL snapshot: at startup the generic core, the wrapper and the testbench are copied to
build/sweep/snapshot/<rtl hash>/, and every point is built from that copy, so editing rtl/ or tb/ while a
sweep runs cannot mix RTL versions under one hash. Run one sweep at a time.

Usage (Questa + Vivado on PATH: `source ./setup.sh vivado`):
  sweep.py --tag baseline --R 1-16 --S 1-4 --U 1,2,4,8 --jobs 4
  sweep.py --tag fastloader --fast 1 --R 4,8,16 --S 1,2,4 --U 2,4
  sweep.py --tag try --R 8 --S 2 --U 2 --dry-run            # list what would run, run nothing
  sweep.py --tag big --U 8 --max-n 16 --max-luts 40000      # tighter size limits
  sweep.py --tag smoke --points r4s1u1,r8s2u2f --no-synth  # explicit points instead of a grid
"""
import argparse
import concurrent.futures as cf
import csv
import datetime
import fcntl
import hashlib
import itertools
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import critpath  # noqa: E402
import fmax  # noqa: E402
import metrics  # noqa: E402

GEN = ROOT / "rtl" / "core_v2_gen"
OUTDIR = ROOT / "reports" / "sweep"
SWEEP_CSV = OUTDIR / "sweep.csv"
RUNS_CSV = OUTDIR / "sweep_runs.csv"
BUILD = ROOT / "build" / "sweep"
LOCK = BUILD / ".lock"
KAT = ROOT / "kat" / "v2" / "gen"
SNAP = BUILD / "snapshot"
SETS = ("edge", "cycles")
DEVICE_LUTS = 63400            # xc7a100t

# LUT estimate, least-squares fit on the synthesized cores (2026-11-19: core_v2_r1..r16, v2, optB, optBC,
# optBCD, v2_gen; within +-9%). Fitted on N <= 4, so larger N is an extrapolation: compare with luts.
LUT_FIXED, LUT_PER_ROUND, LUT_PER_SLOT = 887, 165, 346

CFG_COLS = ["date", "tag", "rtl_hash", "point", "R", "S", "U", "fast_loader",
            "rps", "N", "M", "perm_cycles", "tail_rounds", "rot", "nmask", "luts_est"]
RES_COLS = ["status", "edge_pass", "cycles_pass",
            "fmax_mhz", "closed", "best_period_ns", "wns_ns", "synth_runs",
            "luts", "ffs", "slices", "bram_tiles", "dsps",
            "thr_pt_long", "thr_pt_1536", "thr_pt_64", "thr_pt_16",
            "pct_long_1536", "pct_long_64", "pct_long_16",
            "thr_ad_long", "ad_pt_ratio", "kbps_per_lut_pt", "kbps_per_lut_ad",
            "x_thr_pt_long", "x_thr_pt_16", "x_kbps_per_lut_pt",
            "cyc_blk_pt", "cyc_blk_ad", "cyc_pt_16", "cyc_pt_64", "cyc_pt_1536",
            "crit_class", "crit_src", "crit_dst", "crit_levels", "crit_route_pct", "crit_perm_frac",
            "crit_2nd", "crit_2nd_gap_pct", "crit_3rd", "crit_3rd_gap_pct",
            "part", "vivado", "runtime_s"]
COLS = CFG_COLS + RES_COLS
RUN_COLS = ["date", "tag", "rtl_hash", "point", "iter", "period_ns", "wns_ns", "fmax_est_mhz", "met",
            "luts", "ffs", "slices", "bram_tiles", "dsps", "runtime_s"]


def say(msg):
    print(f"[{datetime.datetime.now():%H:%M:%S}] {msg}", flush=True)


# ---------------------------------------------------------------------------- configuration
def derived(R, S, U):
    """The constants elephant_constants.vhd derives (kept in step with it)."""
    rps, N = R // S, U * S
    M = N // 2
    pc = (80 + rps - 1) // rps
    return dict(rps=rps, N=N, M=M, perm_cycles=pc, tail_rounds=80 - (pc - 1) * rps, rot=pc % S,
                nmask=max(3 * M + 1, N, 3), luts_est=luts_estimate(R, S, U))


def luts_estimate(R, S, U):
    """Rough LUT count: a fixed part (wrapper, control), the round logic (U*R rounds), and per slot (N = U*S:
    state register mux, mask mux, input buffer)."""
    return int(LUT_FIXED + LUT_PER_ROUND * U * R + LUT_PER_SLOT * U * S)


def point_name(R, S, U, fast):
    return f"r{R}s{S}u{U}" + ("f" if fast else "")


SOURCES = (("core", GEN), ("lwc", ROOT / "rtl" / "lwc"), ("tb", ROOT / "tb"))


def rtl_hash(base=None):
    """Hash of everything a point's hardware depends on: the generic core, the wrapper, the testbench."""
    h = hashlib.sha1()
    for sub, d in SOURCES:
        d = base / sub if base else d
        for f in sorted(d.glob("*.vhd")) + sorted(d.glob("filelist.txt")):
            h.update(f.name.encode())
            h.update(f.read_bytes())
    return h.hexdigest()[:10]


def snapshot():
    """Copy the RTL to build/sweep/snapshot/<hash>/ (older snapshots removed); return (hash, folder)."""
    h = rtl_hash()
    dst = SNAP / h
    if not dst.exists():
        tmp = SNAP / f".{h}.tmp"
        shutil.rmtree(tmp, ignore_errors=True)
        for sub, d in SOURCES:
            (tmp / sub).mkdir(parents=True)
            for f in list(d.glob("*.vhd")) + list(d.glob("filelist.txt")):
                shutil.copy(f, tmp / sub / f.name)
        if rtl_hash(tmp) != h:
            raise SystemExit("RTL changed while taking the snapshot; try again")
        tmp.rename(dst)
    for old in SNAP.iterdir():
        if old.name != h:
            shutil.rmtree(old, ignore_errors=True)
    return h, dst


def parse_list(spec):
    """'1-16' / '1,2,4' / '1-4,8' -> sorted ints."""
    out = set()
    for part in str(spec).split(","):
        if "-" in part:
            a, b = part.split("-")
            out.update(range(int(a), int(b) + 1))
        elif part:
            out.add(int(part))
    return sorted(out)


def write_core(dst, R, S, U, fast, snap):
    """Copy the generic core from the snapshot with its configuration constants set; return the
    compile-ordered file list (wrapper and testbench from the snapshot too)."""
    rtl = dst / "rtl"
    rtl.mkdir(parents=True)
    for f in (snap / "core").glob("*.vhd"):
        shutil.copy(f, rtl / f.name)
    c = rtl / "elephant_constants.vhd"
    s = c.read_text()
    for name, val in (("G_R", str(R)), ("G_S", str(S)), ("G_U", str(U)),
                      ("G_FAST_LOADER", "true" if fast else "false")):
        s, n = re.subn(rf"(constant {name} : \w+ := )[^;]+;", rf"\g<1>{val};", s)
        if n != 1:
            raise RuntimeError(f"could not set {name} in {c}")
    c.write_text(s)
    files = []
    for rel in (snap / "core" / "filelist.txt").read_text().split():
        if rel.startswith("rtl/core_v2_gen/"):
            files.append(rtl / Path(rel).name)
        elif rel.startswith("rtl/lwc/"):
            files.append(snap / "lwc" / Path(rel).name)
        else:
            raise RuntimeError(f"unexpected file in the core's filelist: {rel}")
    for rel in (snap / "tb" / "filelist.txt").read_text().split():
        files.append(snap / "tb" / Path(rel).name)
    return files


# ---------------------------------------------------------------------------- simulation
def run_sim(work, files, set_name, testmode):
    """Compile once (first call) and run LWC_TB on one vector set. Returns pass (bool)."""
    simdir = work / "sim" / set_name
    simdir.mkdir(parents=True, exist_ok=True)
    lib = work / "qlib"
    if not (lib / "_info").exists():
        subprocess.run(["vlib", str(lib)], cwd=work, check=True, stdout=subprocess.DEVNULL)
        with (work / "vcom.log").open("w") as log:
            rc = subprocess.run(["vcom", "-2008", "-quiet", "-work", str(lib)] + [str(f) for f in files],
                                cwd=work, stdout=log, stderr=subprocess.STDOUT).returncode
        if rc != 0:
            raise RuntimeError(f"vcom failed; see {work / 'vcom.log'}")
    kat = KAT / set_name
    gens = dict(G_FNAME_PDI=kat / "pdi.txt", G_FNAME_SDI=kat / "sdi.txt", G_FNAME_DO=kat / "do.txt",
                G_FNAME_LOG=simdir / "log.txt", G_FNAME_TIMING=simdir / "timing.txt",
                G_FNAME_TIMING_CSV=simdir / "timing.csv", G_FNAME_FAILED_TVS=simdir / "failed_test_vectors.txt",
                G_FNAME_RESULT=simdir / "result.txt")
    if testmode is not None:
        gens["G_TEST_MODE"] = testmode
    cmd = ["vsim", "-c", "-quiet", "-lib", str(lib)] + [f"-g{k}={v}" for k, v in gens.items()] + \
          ["LWC_TB", "-do", "run -all; quit -f"]
    with (simdir / "sim.out").open("w") as log:
        subprocess.run(cmd, cwd=simdir, stdout=log, stderr=subprocess.STDOUT)
    res = simdir / "result.txt"
    return res.exists() and res.read_text().strip() == "0"


# ---------------------------------------------------------------------------- synthesis
def synth_point(work, files, rps, n, max_iter, log_run, timeout):
    """Fmax search (scripts/fmax.py). Returns (result dict, best run dir)."""
    import synth  # scripts/synth.py: run_vivado, PART
    sdir = work / "synth"
    sdir.mkdir(parents=True, exist_ok=True)
    flist = sdir / "filelist.txt"
    flist.write_text("".join(f"{f}\n" for f in files if f.parent.name != "tb"))

    def run(period):
        t0 = time.time()
        rundir = sdir / f"p{period:.3f}"
        wns, vver, util = synth.run_vivado(flist, period, rundir, timeout)
        return dict(wns=wns, vivado=vver, util=util, dt=time.time() - t0, dir=rundir)

    def log(r):
        log_run(dict(iter=r["iter"], period_ns=f"{r['period']:.3f}", wns_ns=f"{r['wns']:.3f}",
                     fmax_est_mhz=f"{1000.0 / r['achieved']:.1f}", met=int(r["met"]),
                     runtime_s=int(r["dt"]), **r["util"]))

    runs, res = fmax.search(run, fmax.probe_period(rps, n), max_iter, log)
    best = res["run"]
    out = dict(fmax_mhz=f"{res['fmax_mhz']:.1f}", closed=res["closed"], best_period_ns=f"{best['period']:.3f}",
               wns_ns=f"{best['wns']:.3f}", synth_runs=len(runs), part=synth.PART, vivado=best["vivado"],
               **best["util"])
    return out, best["dir"]


# ---------------------------------------------------------------------------- bookkeeping
def append_row(path, cols, row):
    """Append under a lock (several points finish concurrently)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with LOCK.open("a") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        new = not path.exists()
        with path.open("a", newline="") as f:
            w = csv.DictWriter(f, fieldnames=cols)
            if new:
                w.writeheader()
            w.writerow({c: row.get(c, "") for c in cols})


def done_points(tag, h):
    if not SWEEP_CSV.exists():
        return set()
    with SWEEP_CSV.open() as f:
        return {r["point"] for r in csv.DictReader(f) if r["tag"] == tag and r["rtl_hash"] == h}


def baseline_row():
    """core_v2's row of reports/benchmark.csv, for the x_ speedups."""
    f = ROOT / "reports" / "benchmark.csv"
    if f.exists():
        for r in csv.DictReader(f.open()):
            if r["core"] == "v2":
                return r
    return None


def finish(work, ok):
    """Keep only the most recent build (build/sweep/last/); failed points go to build/sweep/failed/."""
    shutil.rmtree(work / "qlib", ignore_errors=True)
    with LOCK.open("a") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        if ok:
            dst = BUILD / "last"
            shutil.rmtree(dst, ignore_errors=True)
        else:
            dst = BUILD / "failed" / work.name
            shutil.rmtree(dst, ignore_errors=True)
            dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(work), str(dst))
    return dst


# ---------------------------------------------------------------------------- one point
def run_point(R, S, U, fast, tag, h, snap, max_iter, no_synth, base, timeout):
    name = point_name(R, S, U, fast)
    t0 = time.time()
    row = dict(date=datetime.datetime.now().isoformat(timespec="seconds"), tag=tag, rtl_hash=h, point=name,
               R=R, S=S, U=U, fast_loader=int(fast), **derived(R, S, U))
    work = BUILD / "work" / name
    shutil.rmtree(work, ignore_errors=True)
    ok = False
    try:
        files = write_core(work, R, S, U, fast, snap)
        say(f"{name}: simulating edge")
        row["edge_pass"] = int(run_sim(work, files, "edge", None))
        if row["edge_pass"]:
            say(f"{name}: simulating cycles")
            row["cycles_pass"] = int(run_sim(work, files, "cycles", 4))
        if not (row["edge_pass"] and row.get("cycles_pass")):
            row["status"] = "sim_fail"
        else:
            cyc = metrics.read_cycles(work / "sim" / "cycles" / "timing.csv")
            cols, blk_pt, blk_ad = metrics.cycle_cols(cyc)
            row.update(cols)
            if no_synth:
                row["status"] = "ok_nosynth"
                ok = True
            else:
                d = derived(R, S, U)
                say(f"{name}: synthesizing (probe {fmax.probe_period(d['rps'], d['N']):.3f} ns)")

                def log_run(r):
                    append_row(RUNS_CSV, RUN_COLS, dict(date=datetime.datetime.now().isoformat(timespec="seconds"),
                                                        tag=tag, rtl_hash=h, point=name, **r))
                    say(f"{name}: Vivado {r['period_ns']} ns -> WNS {float(r['wns_ns']):+.3f} "
                        f"({'met' if r['met'] else 'failed'}), LUT {r['luts']}")
                res, best_run = synth_point(work, files, d["rps"], d["N"], max_iter, log_run, timeout)
                row.update(res)
                row.update(metrics.perf_cols(cyc, blk_pt, blk_ad, float(res["fmax_mhz"]), int(res["luts"])))
                row.update(metrics.speedup_cols(row, base))
                row.update(critpath.summary(best_run))
                row["status"] = "ok"
                ok = True
    except Exception as e:  # keep the sweep going; the row says what happened
        row["status"] = f"error: {e}"[:200]
    row["runtime_s"] = int(time.time() - t0)
    append_row(SWEEP_CSV, COLS, row)
    dst = finish(work, ok)
    say(f"{name}: {row['status']}"
        + (f", {row.get('fmax_mhz')} MHz, {row.get('luts')} LUT, {row.get('cyc_blk_pt')} cyc/blk, "
           f"crit {row.get('crit_class')}"
           + (f" (then {row['crit_2nd']} +{row['crit_2nd_gap_pct']}%)" if row.get("crit_2nd") else "")
           if row["status"] == "ok" else "")
        + ("" if ok else f" (kept in {dst.relative_to(ROOT)})"))
    return row["status"]


# ---------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tag", required=True, help="name of this sweep (rows are grouped and resumed by tag)")
    ap.add_argument("--R", default="1-16", help="rounds per unit, e.g. 1-16 or 4,8,16")
    ap.add_argument("--S", default="1-4", help="pipeline stages per unit")
    ap.add_argument("--U", default="1,2,4,8", help="units")
    ap.add_argument("--fast", default="0", help="fast loader: 0, 1 or 0,1")
    ap.add_argument("--points", default="", help="explicit points instead of the grid, e.g. r4s1u1,r8s2u2f")
    ap.add_argument("--jobs", type=int, default=4, help="points in parallel (each Vivado run uses up to 8 threads)")
    ap.add_argument("--max-iter", type=int, default=fmax.MAX_RUNS, help="Vivado runs per point at most")
    ap.add_argument("--max-n", type=int, default=0, help="skip points with more calls in flight (U*S); 0 = no limit")
    ap.add_argument("--max-luts", type=int, default=int(0.75 * DEVICE_LUTS),
                    help="skip points whose estimated LUTs exceed this (default 75%% of the device)")
    ap.add_argument("--vivado-timeout", type=float, default=3.0, help="hours before a Vivado run is killed")
    ap.add_argument("--no-synth", action="store_true", help="validation and cycles only")
    ap.add_argument("--force", action="store_true", help="re-run points already in sweep.csv for this tag and RTL")
    ap.add_argument("--dry-run", action="store_true", help="list the points, run nothing")
    a = ap.parse_args()

    h = rtl_hash()
    if a.points:
        grid = []
        for name in a.points.split(","):
            m = re.fullmatch(r"r(\d+)s(\d+)u(\d+)(f?)", name.strip())
            if not m:
                sys.exit(f"bad point name {name!r} (expected like r8s2u2 or r8s2u2f)")
            grid.append((int(m.group(1)), int(m.group(2)), int(m.group(3)), int(bool(m.group(4)))))
    else:
        grid = list(itertools.product(parse_list(a.R), parse_list(a.S), parse_list(a.U), parse_list(a.fast)))
    valid = [(R, S, U, bool(f)) for R, S, U, f in grid if R % S == 0]
    skipped = len(grid) - len(valid)
    too_big = [p for p in valid if (a.max_n and p[2] * p[1] > a.max_n) or luts_estimate(*p[:3]) > a.max_luts]
    valid = [p for p in valid if p not in too_big]
    done = set() if a.force else done_points(a.tag, h)
    todo = [p for p in valid if point_name(*p) not in done]
    # cheapest first: small designs and short permutations give feedback early
    todo.sort(key=lambda p: (p[2] * p[0], p[1]))

    say(f"tag {a.tag}, RTL hash {h}: {len(grid)} grid points, {skipped} skipped (S does not divide R), "
        f"{len(too_big)} over the size limits (N > {a.max_n or 'any'} or est. LUTs > {a.max_luts}), "
        f"{len(valid) - len(todo)} already done, {len(todo)} to run with {a.jobs} jobs")
    for R, S, U, f in too_big:
        say(f"  skipped (size): {point_name(R, S, U, f)}  N {U * S}, est. {luts_estimate(R, S, U)} LUT")
    if a.dry_run:
        for R, S, U, f in todo:
            d = derived(R, S, U)
            print(f"  {point_name(R, S, U, f):<12} rounds/stage {d['rps']:>2}  N {d['N']:>2}  "
                  f"cycles/call {d['perm_cycles']:>2}  last-pass rounds {d['tail_rounds']:>2}  masks {d['nmask']:>2}  "
                  f"est. {d['luts_est']:>6} LUT  probe {fmax.probe_period(d['rps'], d['N']):.2f} ns")
        return
    if not KAT.joinpath("edge", "pdi.txt").exists() or not KAT.joinpath("cycles", "pdi.txt").exists():
        sys.exit("vectors missing: run `make kat SPEC=v2` first")
    need = ["vsim", "vcom"] + ([] if a.no_synth else ["vivado"])
    missing = [t for t in need if not shutil.which(t)]
    if missing:
        sys.exit(f"{', '.join(missing)} not on PATH. Run: source ./setup.sh vivado")

    BUILD.mkdir(parents=True, exist_ok=True)
    stale = sorted((BUILD / "work").glob("*")) if (BUILD / "work").exists() else []
    if stale:
        say(f"removing {len(stale)} unfinished point folder(s) from an interrupted run: "
            + ", ".join(d.name for d in stale))
        for d in stale:
            shutil.rmtree(d, ignore_errors=True)
    h, snap = snapshot()
    say(f"RTL snapshot: {snap.relative_to(ROOT)}")
    base = baseline_row()
    statuses = []
    with cf.ProcessPoolExecutor(max_workers=a.jobs) as ex:
        futs = [ex.submit(run_point, R, S, U, f, a.tag, h, snap, a.max_iter, a.no_synth, base,
                          a.vivado_timeout * 3600) for R, S, U, f in todo]
        for fu in cf.as_completed(futs):
            statuses.append(fu.result())
    ok = sum(1 for s in statuses if s.startswith("ok"))
    say(f"done: {ok}/{len(statuses)} ok; results in {SWEEP_CSV.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
