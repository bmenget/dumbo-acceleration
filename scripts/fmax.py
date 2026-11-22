#!/usr/bin/env python3
"""Fmax search shared by scripts/synth.py (named cores) and scripts/sweep.py (design sweep).

Vivado reports slack at a target clock, not a maximum frequency. A run that meets timing at target P with
slack WNS supports any period >= P - WNS (the "achieved" delay), so Fmax = 1000 / (P - WNS) from a run
that met timing. Two observations from reports/synth_runs.csv drive the search
(`fmax.py calibrate` recomputes them):
  - Vivado works hardest under a tight target: the best achieved delay of a core usually comes from a run
    that failed (R=4: 5.67 ns at a 4.5 ns target, never reproduced at looser targets). Once a target is met
    easily, it stops optimizing, so a loose target gives a pessimistic Fmax.
  - Retargeting at the achieved delay rarely meets: the achieved delay moves between runs (first 18
    retargets: <= 4% in 16; with the core_v2_gen smoke runs, 26: <= 4% in 18, <= 5% in 21, <= 8% in 24;
    worst seen +11%). The old rule (next = achieved + 5% of
    the miss) left < 0.5% headroom and met in 4 of 13 such retargets: 2.9 runs per search on average,
    R=4 never closed, optBC took 5 runs, R=8 met on run 2 and then spent 2 more failing to tighten.
Search:
  1. probe: a tight first target, PROBE x the predicted delay, so Vivado pushes and the achieved delay
     measures what the design can do;
  2. if it fails: next target = achieved x (1 + HEADROOM[k]), k = consecutive failures (5%, 10%, 15%);
  3. if it meets: done when a failed run at a tighter target brackets it; otherwise the target was too loose
     (small slack proves nothing: optB met 6.0 ns with 0.019 ns slack, then reached 5.43 ns under a
     5.5 ns target), so tighten to achieved x PROBE and continue.
  Stop at MAX_RUNS. Result: the met run with the smallest achieved delay; if none met, the smallest
  achieved delay as an estimate (closed = 0).
Expected cost: probe + one retarget for most designs (about 2.1 runs, vs. 2.9 with the old rule).
The reported Fmax is then within about HEADROOM[0] of the probe's best achieved delay; the old rule
ended 4-13% above it anyway (optBC 5.90 vs 5.56 ns, optBCD 6.76 vs 5.96 ns).

Usage:
  fmax.py calibrate          headroom/drift table and predictor fit from synth_runs.csv (+ sweep_runs.csv)
"""
import csv
import math
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import core_info  # noqa: E402
PART = "xc7a100tftg256-2L"

# ---- calibration (fmax.py calibrate, 2026-11-19: 29 runs, 10 searches, 9 cores on xc7a100tftg256-2L) -----
# Predicted achievable delay (ns) = max(control floor, permutation path):
#   permutation path: best achieved delay of the permutation-bound cores (rounds per stage 5, 8, 10, 16)
#   control floor:    best achieved delay of the rounds-per-stage <= 4 cores, by permutation calls in flight N
PERM_NS_PER_ROUND = 0.955     # fit: v2_r5, v2_r8, v2 (10), v2_r16
PERM_NS_FIXED = 1.29
CTRL_FLOOR_NS = 4.75          # N = 1: core_v2_gen r4s1u1 4.75 (after the tag-check fix); GMU cores were 5.4-5.7
CTRL_NS_PER_LOG2N = 0.47      # core_v2_gen r8s2u2 (N=4) 5.69; extrapolated beyond N = 4
PROBE = 0.92                  # first target = 8% below the prediction (prediction error seen: -9%..+4%)
HEADROOM = (0.05, 0.10, 0.15) # after 1, 2, 3+ consecutive failures (drift <= 5% in 21 of 26 retargets)
MAX_RUNS = 4


def predict_delay(rounds_per_stage, n=1):
    """Predicted achievable clock period (ns) on PART for a core with this rounds-per-stage and N calls."""
    perm = PERM_NS_PER_ROUND * rounds_per_stage + PERM_NS_FIXED
    ctrl = CTRL_FLOOR_NS + CTRL_NS_PER_LOG2N * math.log2(max(n, 1))
    return max(perm, ctrl)


def probe_period(rounds_per_stage, n=1):
    return round(PROBE * predict_delay(rounds_per_stage, n), 3)


def search(run, first_period, max_runs=MAX_RUNS, log=None):
    """Find Fmax. run(period) -> dict with at least 'wns' (ns); anything else is passed through.

    Returns (runs, result): runs = list of the run dicts with period/achieved/met/iter added;
    result = dict(fmax_mhz, closed, period, wns, run) for the best met run, or the best estimate.
    """
    runs, period, fails = [], first_period, 0
    for it in range(1, max_runs + 1):
        r = dict(run(period))
        wns = r["wns"]
        r.update(iter=it, period=period, achieved=period - wns, met=wns >= 0)
        runs.append(r)
        if log:
            log(r)
        if r["met"]:
            fails = 0
            if any(not x["met"] and x["period"] < period for x in runs):
                break                                    # bracketed by a tighter failed run
            nxt = r["achieved"] * PROBE                  # met easily: Vivado stopped early, push again
        else:
            nxt = r["achieved"] * (1 + HEADROOM[min(fails, len(HEADROOM) - 1)])
            fails += 1
        if any(abs(nxt - x["period"]) < 0.005 for x in runs):
            break
        period = round(nxt, 3)
    met = [x for x in runs if x["met"]]
    best = min(met or runs, key=lambda x: x["achieved"])
    return runs, dict(fmax_mhz=1000.0 / best["achieved"], closed=int(bool(met)), period=best["period"],
                      wns=best["wns"], run=best)


# ---- calibration report -----------------------------------------------------------------------------------


def _sessions():
    """Fmax searches as lists of (period, wns), from synth_runs.csv and sweep_runs.csv."""
    out = []
    f = ROOT / "reports" / "synth_runs.csv"
    if f.exists():
        open_ = {}                                   # searches of different cores interleave (parallel runs)
        for r in csv.DictReader(f.open()):
            if r.get("part") != PART:
                continue
            if r["iter"] == "1":
                open_[r["core"]] = dict(core=r["core"], rounds=r["rounds"], n=core_info.slots(r["core"]), runs=[])
                out.append(open_[r["core"]])
            if r["core"] in open_:
                open_[r["core"]]["runs"].append((float(r["period_ns"]), float(r["wns_ns"])))
    f = ROOT / "reports" / "sweep" / "sweep_runs.csv"
    if f.exists():
        meta = {}
        g = ROOT / "reports" / "sweep" / "sweep.csv"
        if g.exists():
            for r in csv.DictReader(g.open()):
                meta[(r["tag"], r["rtl_hash"], r["point"])] = (r["rps"], int(r["N"]))
        open_ = {}
        for r in csv.DictReader(f.open()):
            key = (r["tag"], r["rtl_hash"], r["point"])
            if r["iter"] == "1":
                rps, n = meta.get(key, ("", 1))
                open_[key] = dict(core=f"sweep:{r['point']}", rounds=rps, n=n, runs=[])
                out.append(open_[key])
            if key in open_:
                open_[key]["runs"].append((float(r["period_ns"]), float(r["wns_ns"])))
    return out


def calibrate():
    ses = _sessions()
    print(f"{sum(len(s['runs']) for s in ses)} runs in {len(ses)} searches on {PART}\n")

    print("Retargets after a failed run: headroom of the next target over the previous achieved delay")
    drifts, buckets = [], defaultdict(lambda: [0, 0])
    for s in ses:
        for (pa, wa), (pb, wb) in zip(s["runs"], s["runs"][1:]):
            if wa >= 0:
                continue
            aa, ab = pa - wa, pb - wb
            h = 100 * (pb / aa - 1)
            drifts.append(100 * (ab / aa - 1))
            b = "<0.5%" if h < 0.5 else "0.5-2%" if h < 2 else "2-4%" if h < 4 else ">=4%"
            buckets[b][0] += wb >= 0
            buckets[b][1] += 1
    for b in ("<0.5%", "0.5-2%", "2-4%", ">=4%"):
        if b in buckets:
            m, n = buckets[b]
            print(f"  headroom {b:>7}: met {m}/{n}")
    if drifts:
        ds = sorted(drifts)
        for t in (2, 3, 4, 5, 8):
            print(f"  achieved-delay drift <= {t}%: {sum(d <= t for d in ds)}/{len(ds)}")
        print(f"  worst drift: {max(ds):+.1f}%")

    print("\nBest achieved delay per search (met or not) vs prediction")
    perm_pts, rows = [], []
    for s in ses:
        best = min(p - w for p, w in s["runs"])
        try:
            rps = int(s["rounds"])
        except ValueError:
            continue
        pred = predict_delay(rps, s["n"])
        rows.append((s["core"], rps, s["n"], best, pred))
        if rps >= 5 and s["n"] == 1:
            perm_pts.append((rps, best))
    for core, rps, n, best, pred in rows:
        print(f"  {core:<16} rounds/stage {rps:>2}  N {n:>2}  best {best:6.3f}  predicted {pred:6.3f} "
              f"({100 * (pred / best - 1):+.1f}%)")
    if len(perm_pts) >= 2:
        xs, ys = zip(*perm_pts)
        mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
        slope = sum((x - mx) * (y - my) for x, y in perm_pts) / sum((x - mx) ** 2 for x in xs)
        print(f"\n  permutation-path fit (rounds/stage >= 5, N = 1): {slope:.3f} ns/round + {my - slope * mx:.3f} ns"
              f"   (in use: {PERM_NS_PER_ROUND} + {PERM_NS_FIXED})")
    runs_used = [len(s["runs"]) for s in ses]
    print(f"\n  runs per search so far: mean {sum(runs_used) / len(runs_used):.1f}, max {max(runs_used)}")


if __name__ == "__main__":
    if sys.argv[1:] == ["calibrate"]:
        calibrate()
    else:
        print(__doc__)
