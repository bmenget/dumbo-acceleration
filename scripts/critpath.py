#!/usr/bin/env python3
"""Classify the critical paths in a Vivado timing report (report_timing_summary, max delay paths).

Each path gets one category:
  perm           most logic cells lie inside a permutation unit (GMU cores: .../PERM/, PERM_B/;
                 brody/gen: .../gen_stage[i].ST/), or, when Vivado flattened that hierarchy, the path
                 runs from the round counter or a state register into a state/key register. The clock is
                 set by the rounds per stage (an in-place unmask path also matches the second rule; it is
                 short and rarely critical).
  wrapper        source and destination inside the LWC wrapper (Pre/PostProcessor, header FIFO)
  core->wrapper  core logic (handshake, bdo, tag compare) into a wrapper register
  wrapper->core  wrapper register into the core
  tag            ends in the tag accumulator
  lfsr           ends in the mask LFSR window
  ctrl->datapath control register (FSM, counters, loader flags, registered selects) into a datapath
                 register (state/slot, key, buffers, keystream) through mux selects / enables
  ctrl           control register to control register
  datapath       datapath register to datapath register, not through the permutation (masks, buffers)
Plus: logic levels, routing share of the delay, and the share of logic cells inside a permutation unit.
Vivado sometimes files a LUT under an unrelated hierarchy (e.g. the state input mux under DATAP_LFSR/), so
categories rest on endpoints plus the permutation-cell share, not on every cell's name.

Distinct categories: the 5 detailed paths of timing.rpt are usually bits of one bus (all the same category),
so the summary also reads paths.tsv (written by vivado_build.tcl: the worst path to each of up to 1000
endpoints) and lists the 3 worst DISTINCT categories, each with its gap: how much the clock period could
shrink (%) before that category becomes critical. A gap near 0 means two bottlenecks are tied.

Usage:
  critpath.py <run dir or timing.rpt>   classify one Vivado run
  critpath.py --core brody/r4_BtoD     the best run of a named core's latest synthesis
"""
import argparse
import csv
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

WRAPPER = ("Inst_PreProcessor/", "Inst_PostProcessor/", "Inst_Header_Fifo/")
CORE = "Inst_Cipher/"
DATAPATH = "Inst_Cipher/ELEPHANT_DATAP/"
PERM_MARK = re.compile(r"/(PERM|PERM_B)/|gen_stage\[\d+\]\.ST/|gen_perm\[\d+\]\.P/")
# datapath registers that are control in nature (registered selects/enables living in the datapath)
DP_CTRL_REGS = re.compile(r"(mode_q|unmask_q)")
# registers between which a permutation stage always sits: GMU cores' state registers and key register,
# brody/gen's slot registers; and the round counter, which selects the round constants
STATE_REG = re.compile(r"gen_reg\[\d+\]\.r_reg|/r_reg\[|ms_reg_out_reg|msb_reg|key_out_reg")
ROUND_CNT = re.compile(r"perm_cnt_int_reg")
LOGIC_CELL = re.compile(r"^\s+SLICE_\S+\s+(LUT\d|CARRY4|MUXF\d)\b.*\s(\S+)$")


def short(name):
    """Readable register name: hierarchy shortened, bit index and pin dropped."""
    n = re.sub(r"/[A-Z]+$", "", name)                       # /C, /D, /CE, /R pins
    n = n.replace(DATAPATH, "dp/").replace(CORE, "core/")
    for w in WRAPPER:
        n = n.replace(w, w.replace("Inst_", "").rstrip("/") + "/")
    n = re.sub(r"\[\d+\]", "", n)                           # bit / element indices
    n = n.replace("FSM_sequential_", "").replace("FSM_32BIT.GEN_proc_SYNC_RST.", "")
    n = re.sub(r"_reg(_rep(__\d+)?)?$", "", n)              # Vivado register suffixes
    return n


def side(name):
    """'wrapper', 'perm', 'tag', 'lfsr', 'datapath', or 'ctrl' for a register name."""
    if name.startswith(WRAPPER):
        return "wrapper"
    if name.startswith(DATAPATH):
        if DP_CTRL_REGS.search(name):
            return "ctrl"
        if "tag_out" in name:
            return "tag"
        if "lfsr_output" in name or "DATAP_LFSR/" in name and "lfsr" in name:
            return "lfsr"
        return "datapath"
    if name.startswith(CORE):
        return "ctrl"
    return "other"


def parse(report):
    """List of path dicts from the 'Max Delay Paths' section."""
    text = Path(report).read_text()
    start = text.find("Max Delay Paths")
    if start < 0:
        return []
    paths = []
    for block in re.split(r"\n(?=Slack )", text[start:])[1:]:
        p = {}
        m = re.search(r"^Slack \((\w+)\)\s*:\s*(-?[\d.]+)ns", block, re.M)
        if not m:
            continue
        p["met"], p["slack"] = m.group(1), float(m.group(2))
        p["src"] = re.search(r"Source:\s+(\S+)", block).group(1)
        p["dst"] = re.search(r"Destination:\s+(\S+)", block).group(1)
        m = re.search(r"Data Path Delay:\s+([\d.]+)ns\s+\(logic ([\d.]+)ns.*route ([\d.]+)ns", block)
        p["delay"], p["logic_ns"], p["route_ns"] = (float(m.group(i)) for i in (1, 2, 3))
        m = re.search(r"Logic Levels:\s+(\d+)", block)
        p["levels"] = int(m.group(1))
        # logic cells of the data path (between the source and destination flip-flops)
        cells = [c.group(2) for c in (LOGIC_CELL.match(l) for l in block.splitlines()) if c]
        p["cells"] = cells
        p["perm_frac"] = (sum(1 for c in cells if PERM_MARK.search(c)) / len(cells)) if cells else 0.0
        p["category"] = classify(p)
        paths.append(p)
    return paths


def classify(p):
    s, d = side(p["src"]), side(p["dst"])
    if p["perm_frac"] >= 0.5:
        return "perm"
    # Vivado can flatten a stage's hierarchy (seen on small single-stage cores), leaving no stage names in
    # the path; endpoints still identify it: round counter or state register -> state/key register
    if STATE_REG.search(p["dst"]) and (ROUND_CNT.search(p["src"]) or STATE_REG.search(p["src"])):
        return "perm"
    if d == "wrapper":
        return "wrapper" if s == "wrapper" else "core->wrapper"
    if s == "wrapper":
        return "wrapper->core"
    if d == "tag":
        return "tag"
    if d == "lfsr":
        return "lfsr"
    if s == "ctrl" and d in ("datapath",):
        return "ctrl->datapath"
    if s == "ctrl" and d == "ctrl":
        return "ctrl"
    if s in ("datapath", "lfsr", "tag") and d == "ctrl":
        return "datapath->ctrl"
    return "datapath"


def parse_tsv(tsv):
    """Paths from paths.tsv (one line per endpoint, worst first)."""
    out = []
    with Path(tsv).open() as f:
        next(f)
        for line in f:
            sl, lv, dl, lg, src, dst, n, np_ = line.rstrip("\n").split("\t")
            try:
                float(sl)
            except ValueError:
                continue                                    # unconstrained (port) path: no slack
            p = dict(slack=float(sl), levels=int(lv), delay=float(dl), src=src, dst=dst,
                     perm_frac=int(np_) / int(n) if int(n) else 0.0)
            p["category"] = classify(p)
            out.append(p)
    return out


def distinct(paths, period, k=3):
    """[(category, gap %)] for the k worst distinct categories; gap relative to the worst path."""
    paths = sorted(paths, key=lambda p: p["slack"])
    worst = paths[0]["slack"]
    seen, out = set(), []
    for p in paths:
        if p["category"] not in seen:
            seen.add(p["category"])
            out.append((p["category"], 100 * (p["slack"] - worst) / (period - worst)))
            if len(out) == k:
                break
    return out


def _period(report):
    m = re.search(r"Requirement:\s+([\d.]+)ns", Path(report).read_text())
    return float(m.group(1)) if m else None


def summary(run):
    """Columns for the sweep CSV: the worst path's details, plus the 2nd and 3rd distinct categories."""
    run = Path(run)
    report = run / "timing.rpt" if run.is_dir() else run
    paths = parse(report)
    if not paths:
        return {}
    w = paths[0]
    tsv = report.parent / "paths.tsv"
    pool = parse_tsv(tsv) if tsv.exists() else paths          # older runs: only the 5 detailed paths
    cats = distinct(pool, _period(report))
    out = dict(crit_class=w["category"], crit_src=short(w["src"]), crit_dst=short(w["dst"]),
               crit_levels=w["levels"], crit_route_pct=f"{100 * w['route_ns'] / w['delay']:.0f}",
               crit_perm_frac=f"{w['perm_frac']:.2f}")
    for i, name in ((1, "2nd"), (2, "3rd")):
        if i < len(cats):
            out[f"crit_{name}"] = cats[i][0]
            out[f"crit_{name}_gap_pct"] = f"{cats[i][1]:.1f}"
    return out


def best_report(core):
    """timing.rpt of the run synth.py reported for the core's latest synthesis."""
    rows = [r for r in csv.DictReader((ROOT / "reports" / "synth_results.csv").open()) if r["core"] == core]
    if not rows:
        sys.exit(f"no synthesis of {core} in reports/synth_results.csv")
    period = rows[-1]["best_period_ns"]
    f = ROOT / "build" / "synth" / core / f"p{period}" / "timing.rpt"
    if not f.exists():
        sys.exit(f"{f} not found (build/ was cleaned?)")
    return f


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("report", nargs="?", help="Vivado run directory or its timing.rpt")
    ap.add_argument("--core", help="named core: use its latest synthesis' best run")
    a = ap.parse_args()
    if not (a.report or a.core):
        ap.error("give a timing.rpt or --core")
    f = best_report(a.core) if a.core else Path(a.report)
    if f.is_dir():
        f = f / "timing.rpt"
    print(f"{f}")
    print(f"{'#':>2} {'slack':>7} {'lvl':>3} {'route':>5} {'perm':>5}  {'category':<15} source -> destination")
    paths = parse(f)
    for i, p in enumerate(paths, 1):
        print(f"{i:>2} {p['slack']:>7.3f} {p['levels']:>3} {100 * p['route_ns'] / p['delay']:>4.0f}% "
              f"{p['perm_frac']:>5.2f}  {p['category']:<15} {short(p['src'])} -> {short(p['dst'])}")
    tsv = f.parent / "paths.tsv"
    pool = parse_tsv(tsv) if tsv.exists() else paths
    print(f"\ndistinct categories ({len(pool)} paths from {'paths.tsv' if tsv.exists() else 'timing.rpt only'}); "
          f"gap = how much the period could shrink before it becomes critical:")
    for c, g in distinct(pool, _period(f)):
        print(f"  {c:<15} {g:5.1f}%")


if __name__ == "__main__":
    main()
