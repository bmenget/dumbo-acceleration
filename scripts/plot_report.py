#!/usr/bin/env python3
"""Report graphs: the optimization path, our cores against GMU's published LWC results, and the evidence
behind the design decisions. Writes PNGs into reports/graphs/.

  python3 scripts/plot_report.py            # needs matplotlib; `make plots`

Inputs (all already in the repo):
  reports/benchmark.csv        make report: one row per named core
  reports/gmu_published.csv    GMU's unprotected results, ePrint 2023/484 Tables 12 + 14 (docs/SCA-Benchmarking.pdf)
  reports/profile.csv          make profile WL=long: where the cycles go
  reports/synth_runs.csv       every Vivado run (target period, WNS, met)
  reports/nks_study.csv        keystream FIFO depth vs cycles per block (measured by hand, see the notes)
  reports/sweep/sweep.csv      design-space sweep of brody/gen (optional)
  build/synth/<core>/.../util_hier.rpt   per-hierarchy area (cores synthesized after it was added)
  build/sim/questa/brody/r4_BtoH/prof_long/prof.vcd   slot activity for the timeline

Graphs (numbered as in the report outline):
  01_cycles_per_block.png      PT and AD cycles per 20 B block along the optimization path, bus limit
  02_throughput_progress.png   long-message PT throughput per step, speedup over brody/base
  03_fmax_area_progress.png    Fmax and LUT / FF per step
  04_efficiency_progress.png   Kbps/LUT per step against Elephant_GMU and the finalists' average
  05_pareto_all.png            throughput vs LUTs: our cores, the sweep, all GMU-benchmarked finalists
  06_thr_vs_msgsize.png        PT throughput at 16 / 64 / 1536 B / long
  07_efficiency_ranked.png     Kbps/LUT ranking, our cores among the finalists
  08_ad_vs_pt.png              long-message AD vs PT throughput per step
  09_cycle_breakdown.png       permutation / I/O overlap per step (long workload)
  10_area_breakdown.png        LUT sites and FFs by part: r4_BtoG, r4_BtoH, r2 variant
  11_fmax_vs_rps.png           Fmax vs rounds per stage: sweep, our cores, Elephant_GMU
  12_nks_sensitivity.png       cycles per block vs keystream FIFO depth
  13_slot_timeline.png         every permutation call by kind + bus words: a 16 B message, long steady state
  14_synth_noise.png           WNS vs target period for r4_BtoG and r4_BtoH (Vivado noise)
  15_thr_vs_luts.png           throughput vs LUTs on linear axes: our path and GMU's finalists only
  16_logan_msgsize.png         throughput vs message size: our two fastest cores against Logan's two fastest
Logan's SystemVerilog cores (rtl/logan/src/, CORE=logan/*; with our changes, CORE=merged/*) appear in 05, 07, 09, 11, 15 and 16, always in aqua (C3)
with square markers; they are not steps of our optimization path.
"""
import csv
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import plot_sweep as ps  # noqa: E402  (sets rcParams: shared look with the sweep graphs)
from plot_sweep import AXIS, GRID, INK, INK2, MUTED, SURF, fnum, pareto, plt  # noqa: E402

ROOT = ps.ROOT
REP = ROOT / "reports"
OUT = REP / "graphs"

# categorical slots in fixed order (validated default palette); context marks stay gray
C1, C2, C3, C4 = "#2a78d6", "#eb6834", "#1baf7a", "#eda100"
LIGHTBLUE = "#86b6ef"
CONTEXT = "#b9b7ae"

# the optimization path: core, short label, what the step did
STEPS = [
    ("brody/base", "base", "baseline\nR=10"),
    ("brody/base_r4", "base_r4", "R=4"),
    ("brody/r4_B", "+B", "I/O\noverlap"),
    ("brody/r4_BtoC", "+C", "2 units"),
    ("brody/r4_BtoD", "+D", "2-stage\npipeline"),
    ("brody/r4_BtoE", "+E", "stagger\ncalls"),
    ("brody/r4_BtoF", "+F", "fast\nloader"),
    ("brody/r4_BtoG", "+G", "8 slots"),
    ("brody/r4_BtoH", "+H", "stage-0\nloads"),
    ("brody/r4_BtoI", "+I", "registered\nhandshake"),
    ("brody/r4_BtoJ", "+J", "mask\nselect"),
]
REFS = ["brody/base_r1", "brody/base_r5", "brody/base_r8", "brody/base_r16"]            # brody/base at other rounds per cycle
FINAL = "brody/r4_BtoJ"                             # the final core of the optimization path
R2 = "brody/r2_BtoL"                             # 2 rounds per stage: J's RTL + K, L (handshake paths)
R2H = "brody/r2_BtoH"                                # ... and before option I
NICE = {"brody/base": "base (baseline)", FINAL: "r4_BtoJ", "brody/r4_BtoI": "r4_BtoI", "brody/r4_BtoH": "r4_BtoH",
        "brody/r4_BtoG": "r4_BtoG", "brody/r4_BtoF": "r4_BtoF", R2: "r2_BtoL",
        R2H: "r2_BtoH", "brody/base_r1": "base_r1",
        "brody/base_r5": "base_r5", "brody/base_r8": "base_r8", "brody/base_r16": "base_r16", "brody/base_r4": "base_r4"}
# Logan's cores (rtl/logan/src/): same flow, wrapper and part as ours. core, short label, configuration
LOGAN = [
    ("logan/r4", "Logan R=4", "iterative"),
    ("logan/pipe16x1d16", "Logan 16×1", "ring"),
    ("logan/pipe10x2d8", "Logan 10×2", "ring"),
    ("logan/pipe20x2d16", "Logan 20×2", "ring"),
]
CL = C3          # Logan's series color (validated with C1 and C2 on all pairs; aqua needs direct labels)
NICE.update({c: f"{s} {m}" for c, s, m in LOGAN})
# Logan's rings with our changes (rtl/merged/pipe*): core, short label, name, the core it builds on.
# Drawn as hollow aqua squares chained from his base cores, like our optimization path.
LOGAN_OPT = [
    ("merged/pipe20x2d16_I", "+I", "Logan 20×2 + our I", "logan/pipe20x2d16"),
    ("merged/pipe20x2d16_IL", "+I, L", "Logan 20×2 + our I, L", "merged/pipe20x2d16_I"),
    ("merged/pipe16x2d16_ILN", "32-round ring", "Logan ring 16×2, 2 entry points + our I, L",
     "merged/pipe20x2d16_IL"),
    ("merged/pipe10x2d8_IL", "+I, L", "Logan 10×2 + our I, L", "logan/pipe10x2d8"),
]
NICE.update({c: n for c, _, n, _ in LOGAN_OPT})
# short labels for the first steps of the r4 path
NICE.update({"brody/r4_B": "r4_B", "brody/r4_BtoC": "r4_BtoC", "brody/r4_BtoD": "r4_BtoD", "brody/r4_BtoE": "r4_BtoE"})
H_NOISE_SINCE = "2026-11-20T14:50"   # r4_BtoH runs after the keystream FIFO change (final RTL)


def nice(c):
    return NICE.get(c, c.rsplit("/", 1)[-1])


# ---------------------------------------------------------------------------------------------- data
def read_csv(p):
    return list(csv.DictReader(open(p))) if p.exists() else []


def load_bench():
    return {r["core"]: {k: (fnum(v) if k not in ("core", "part", "synth_date", "cycles_date", "checks") else v)
                        for k, v in r.items()} for r in read_csv(REP / "benchmark.csv")}


def load_gmu():
    out = []
    for r in read_csv(REP / "gmu_published.csv"):
        out.append({k: (v if k in ("impl", "algorithm") else fnum(v)) for k, v in r.items()})
    return out


def load_profile():
    best = {}
    for r in read_csv(REP / "profile.csv"):
        if r["workload"] == "long" and (r["core"] not in best or r["date"] > best[r["core"]]["date"]):
            best[r["core"]] = r
    return best


def util_hier(core):
    """LUT sites and FFs by part, from the util_hier.rpt of the core's latest closed synthesis."""
    rows = [r for r in read_csv(REP / "synth_results.csv") if r["core"] == core and r["closed"] == "1"]
    cands = []
    if rows:
        per = float(max(rows, key=lambda r: r["date"])["best_period_ns"])
        cands.append(ROOT / "build" / "synth" / core / f"p{per:.3f}" / "util_hier.rpt")
    cands.append(ROOT / "build" / "synth" / core / "hier" / "util_hier.rpt")
    f = next((c for c in cands if c.exists()), None)
    if not f:
        return None
    parts = {"lut": {}, "ff": {}}
    top = None
    for line in f.read_text().splitlines():
        cells = [c.strip() for c in line.split("|")]
        if len(cells) < 9 or not cells[3].isdigit():
            continue
        inst, lut, ff = cells[1], int(cells[3]), int(cells[7])
        if top is None:
            top = (lut, ff)
        if inst == "Inst_Cipher":
            parts["lut"]["wrapper"], parts["ff"]["wrapper"] = top[0] - lut, top[1] - ff
        elif inst == "(Inst_Cipher)":
            parts["lut"]["control"], parts["ff"]["control"] = lut, ff
        elif inst == "(ELEPHANT_DATAP)":
            parts["lut"]["datapath"], parts["ff"]["datapath"] = lut, ff
        elif inst == "ELEPHANT_DATAP":
            dp_total = (lut, ff)
        elif re.match(r"gen_perm\[\d+\]\.P", inst):
            parts["lut"]["rounds"] = parts["lut"].get("rounds", 0) + lut
            parts["ff"]["rounds"] = parts["ff"].get("rounds", 0) + ff
    for u, k in (("lut", 0), ("ff", 1)):          # the rest of the datapath: the two mask LFSRs
        parts[u]["lfsr"] = dp_total[k] - parts[u]["datapath"] - parts[u].get("rounds", 0)
    parts["total"] = top
    parts["src"] = f.relative_to(ROOT)
    return parts


# ---------------------------------------------------------------------------------------------- helpers
def save(fig, name):
    OUT.mkdir(parents=True, exist_ok=True)
    fig.savefig(OUT / name, dpi=170, bbox_inches="tight")
    plt.close(fig)
    print(f"wrote {OUT / name}")


def footer(fig, text):
    """Source / caption line, placed under everything already drawn (tick labels included)."""
    fig.canvas.draw()
    y0 = fig.get_tightbbox(fig.canvas.get_renderer()).y0 / fig.get_figheight()
    fig.text(0.01, y0 - 0.012, text, color=MUTED, fontsize=7.5, ha="left", va="top")


def patches(items):
    from matplotlib.patches import Patch
    return [Patch(facecolor=c, edgecolor="none", label=l) for l, c in items]


def step_axis(ax, steps):
    ax.set_xticks(range(len(steps)))
    ax.set_xticklabels([f"{s}\n{m}" for _, s, m in steps], fontsize=8)
    ax.tick_params(axis="x", length=0)
    ax.grid(axis="x", visible=False)


def steps_in(bench):
    return [s for s in STEPS if s[0] in bench]


def logan_in(bench):
    return [s for s in LOGAN if s[0] in bench]


def logan_points(ax, bench, xkey, ykey, offsets, label="Logan's cores (SystemVerilog)", fmt=None):
    """Logan's cores as aqua squares, each directly labeled in ink. offsets: core -> (dx, dy, ha[, leader])."""
    lg = logan_in(bench)
    if not lg:
        return
    xs = [bench[c][xkey] for c, _, _ in lg]
    ys = [bench[c][ykey] for c, _, _ in lg]
    ax.scatter(xs, ys, marker="s", s=46, color=CL, edgecolor=SURF, linewidth=1, label=label, zorder=6)
    for (c, s, m), x, y in zip(lg, xs, ys):
        dx, dy, ha, *lead = offsets.get(c, (7, -4, "left"))
        txt = fmt(c, s, x, y) if fmt else s
        arrow = dict(arrowstyle="-", color=AXIS, lw=0.6, shrinkA=1, shrinkB=4) if lead and lead[0] else None
        ax.annotate(txt, (x, y), xytext=(dx, dy), textcoords="offset points", fontsize=8, color=INK,
                    fontweight="bold", ha=ha, va="center", arrowprops=arrow)


def logan_opt_points(ax, bench, xkey, ykey, offsets, label="Logan's rings with our changes", fmt=None):
    """Logan's rings with our changes: hollow aqua squares, each linked to the core it builds on."""
    lo = [(c, s, pred) for c, s, _, pred in LOGAN_OPT if c in bench]
    if not lo:
        return
    for c, _, pred in lo:
        if pred in bench:
            ax.plot([bench[pred][xkey], bench[c][xkey]], [bench[pred][ykey], bench[c][ykey]], color=CL, lw=1.2,
                    zorder=5)
    ax.scatter([bench[c][xkey] for c, _, _ in lo], [bench[c][ykey] for c, _, _ in lo], marker="s", s=46,
               facecolor=SURF, edgecolor=CL, linewidth=1.6, label=label, zorder=6)
    for c, s, _ in lo:
        x, y = bench[c][xkey], bench[c][ykey]
        dx, dy, ha = offsets.get(c, (7, 0, "left"))
        ax.annotate(fmt(c, s, x, y) if fmt else s, (x, y), xytext=(dx, dy), textcoords="offset points",
                    fontsize=8, color=INK, fontweight="bold", ha=ha, va="center")


def hline(ax, y, text, color=INK2, ls=(0, (4, 3)), side="right", va="bottom", legend=False):
    if legend:                       # label in the legend (when a text label would sit on bars)
        ax.axhline(y, color=color, lw=1.1, ls=ls, zorder=3, label=text)
        return
    ax.axhline(y, color=color, lw=1.1, ls=ls, zorder=1)
    x = 0.995 if side == "right" else 0.005
    ax.text(x, y, f" {text} ", transform=ax.get_yaxis_transform(), ha=side, va=va, color=INK2, fontsize=7.5,
            bbox=dict(facecolor=SURF, edgecolor="none", pad=0.5))


def spread(vals, gap):
    """Nudge sorted label positions apart by at least `gap` (same units as vals)."""
    order = sorted(range(len(vals)), key=lambda i: vals[i])
    out = list(vals)
    for a, b in zip(order, order[1:]):
        if out[b] - out[a] < gap:
            out[b] = out[a] + gap
    return out


# ---------------------------------------------------------------------------------------------- 1-4, 8: progress
def g01_cycles(bench):
    st = steps_in(bench)
    x = range(len(st))
    pt = [bench[c]["cyc_blk_pt"] for c, _, _ in st]
    ad = [bench[c]["cyc_blk_ad"] for c, _, _ in st]
    fig, ax = plt.subplots(figsize=(9.5, 5))
    ax.set_yscale("log")
    hline(ax, 5, "32-bit bus limit: 5 cycles per 20 B block", ls=(0, (4, 3)), va="top", side="left")
    ax.plot(x, pt, color=C1, lw=2, marker="o", ms=7, mec=SURF, mew=1.5, label="plaintext", zorder=3)
    ax.plot(x, ad, color=C2, lw=2, marker="s", ms=7, mec=SURF, mew=1.5, label="associated data", zorder=3)
    for series, col, dy in ((pt, C1, 8), (ad, C2, -12)):
        for i in (0, len(st) - 1):
            ax.annotate(f"{series[i]:.2f}", (i, series[i]), xytext=(0, dy), textcoords="offset points",
                        ha="center", fontsize=8, color=INK)
    ax.annotate("plaintext", (len(st) - 1, pt[-1]), xytext=(14, 10), textcoords="offset points", color=INK2,
                fontsize=8.5, fontweight="bold")
    ax.annotate("associated data", (len(st) - 1, ad[-1]), xytext=(14, -14), textcoords="offset points",
                color=INK2, fontsize=8.5, fontweight="bold")
    ax.set_yticks([4, 5, 7, 10, 20, 30, 50])
    ax.get_yaxis().set_major_formatter(plt.FuncFormatter(lambda v, _: f"{v:g}"))
    ax.set_ylim(3.6, max(pt + ad) * 1.25)
    ax.set_xlim(-0.4, len(st) - 0.2)
    step_axis(ax, st)
    ax.set_ylabel("cycles per 20 B block (log scale)")
    ax.set_title("Cycles per block along the optimization path")
    ax.legend(loc="upper right")
    footer(fig, "Long messages (1536 B), measured with make cycles. Each step includes the ones before it.")
    save(fig, "01_cycles_per_block.png")


def g02_throughput(bench):
    st = steps_in(bench)
    thr = [bench[c]["thr_pt_long"] for c, _, _ in st]
    base = bench["brody/base"]["thr_pt_long"]
    fig, ax = plt.subplots(figsize=(9.5, 5))
    ax.bar(range(len(st)), thr, color=C1, width=0.62, edgecolor=SURF, linewidth=2, zorder=2)
    for i, v in enumerate(thr):
        ax.text(i, v + max(thr) * 0.012, f"×{v / base:.1f}", ha="center", va="bottom", fontsize=8.5,
                color=INK, fontweight="bold" if i == len(st) - 1 else "normal")
    ax.text(len(st) - 1, thr[-1] * 0.5, f"{thr[-1]:,.0f}\nMbit/s", ha="center", va="center", color="#ffffff",
            fontsize=8.5, fontweight="bold")
    step_axis(ax, st)
    ax.set_ylim(0, max(thr) * 1.1)
    ax.set_ylabel("long-message plaintext throughput (Mbit/s)")
    ax.set_title("Throughput along the optimization path")
    footer(fig, "Throughput = 160 bits per block × Fmax / cycles per block (GMU's long-message definition); "
                "labels are speedups over the baseline, brody/base.")
    save(fig, "02_throughput_progress.png")


def g03_fmax_area(bench, gmu):
    st = steps_in(bench)
    x = list(range(len(st)))
    eg = next((g for g in gmu if g["impl"] == "Elephant_GMU"), None)
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(9.5, 6.8), sharex=True, gridspec_kw=dict(hspace=0.12,
                                                                                         height_ratios=[1, 1.3]))
    f = [bench[c]["fmax_mhz"] for c, _, _ in st]
    a1.plot(x, f, color=C1, lw=2, marker="o", ms=7, mec=SURF, mew=1.5, zorder=3)
    for i, v in enumerate(f):
        a1.annotate(f"{v:.0f}", (i, v), xytext=(0, 7), textcoords="offset points", ha="center", fontsize=7.5,
                    color=INK2)
    if eg:
        hline(a1, eg["fmax_mhz"], f"Elephant_GMU {eg['fmax_mhz']:.0f} MHz", va="top")
    a1.set_ylim(0, 245)
    a1.grid(axis="x", visible=False)
    a1.set_ylabel("Fmax (MHz)")
    a1.set_title("Clock and area along the optimization path")
    w = 0.36
    lut = [bench[c]["luts"] for c, _, _ in st]
    ff = [bench[c]["ffs"] for c, _, _ in st]
    a2.bar([i - w / 2 for i in x], lut, width=w, color=C1, edgecolor=SURF, linewidth=1.5, label="LUTs", zorder=2)
    a2.bar([i + w / 2 for i in x], ff, width=w, color=C2, edgecolor=SURF, linewidth=1.5, label="FFs", zorder=2)
    if eg:
        hline(a2, eg["luts"], f"Elephant_GMU LUTs ({eg['luts']:,.0f})", legend=True)
    a2.set_ylabel("LUTs / FFs")
    a2.legend(loc="upper left", bbox_to_anchor=(0.0, 0.93))
    step_axis(a2, st)
    footer(fig, "Fmax: closed timing in Vivado 2026.1, xc7a100tftg256-2L, out of context, LWC wrapper included.")
    save(fig, "03_fmax_area_progress.png")


def g04_efficiency(bench, gmu):
    st = steps_in(bench)
    e = [bench[c]["kbps_per_lut_pt"] for c, _, _ in st]
    fig, ax = plt.subplots(figsize=(9.5, 5))
    ax.bar(range(len(st)), e, color=C1, width=0.62, edgecolor=SURF, linewidth=2, zorder=2)
    for i, v in enumerate(e):
        ax.text(i, v + 12, f"{v:.0f}", ha="center", va="bottom", fontsize=8, color=INK)
    eg = next((g for g in gmu if g["impl"] == "Elephant_GMU"), None)
    if eg:
        hline(ax, eg["kbps_per_lut_pt"], f"Elephant_GMU ({eg['kbps_per_lut_pt']:.0f})", legend=True)
    if gmu:
        avg = sum(g["kbps_per_lut_pt"] for g in gmu) / len(gmu)
        hline(ax, avg, f"average of GMU's 30 unprotected finalist designs ({avg:.0f})", color=MUTED,
              ls=(0, (1, 2)), legend=True)
    ax.legend(loc="upper left")
    step_axis(ax, st)
    ax.set_ylim(0, max(e) * 1.12)
    ax.set_ylabel("long-message PT throughput / area (Kbit/s per LUT)")
    ax.set_title("Throughput per LUT along the optimization path")
    footer(fig, "GMU values: Mohajerani et al., ePrint 2023/484, Table 14 (same part).")
    save(fig, "04_efficiency_progress.png")


def g08_ad_vs_pt(bench):
    st = steps_in(bench)
    w = 0.36
    pt = [bench[c]["thr_pt_long"] for c, _, _ in st]
    ad = [bench[c]["thr_ad_long"] for c, _, _ in st]
    fig, ax = plt.subplots(figsize=(9.5, 5))
    ax.bar([i - w / 2 for i in range(len(st))], pt, width=w, color=C1, edgecolor=SURF, linewidth=1.5,
           label="plaintext", zorder=2)
    ax.bar([i + w / 2 for i in range(len(st))], ad, width=w, color=C2, edgecolor=SURF, linewidth=1.5,
           label="associated data", zorder=2)
    for i, c in enumerate(st):
        r = bench[c[0]]["ad_pt_ratio"]
        ax.text(i, max(pt[i], ad[i]) + 70, f"AD/PT\n{r:.2f}", ha="center", va="bottom", fontsize=7, color=INK2)
    step_axis(ax, st)
    ax.set_ylim(0, max(pt + ad) * 1.18)
    ax.set_ylabel("long-message throughput (Mbit/s)")
    ax.set_title("Associated data vs plaintext throughput")
    ax.legend(loc="upper left")
    footer(fig, "AD needs one MAC call per block, PT a MAC and a keystream call, so AD ran ~1.9× faster until "
                "both reached the bus limit (+G).")
    save(fig, "08_ad_vs_pt.png")


# ---------------------------------------------------------------------------------------------- 5-7: vs GMU
def g05_pareto(bench, gmu, sweep):
    fig, ax = plt.subplots(figsize=(10, 6.6))
    ax.set_xscale("log")
    ax.set_yscale("log")
    xs = [500, 12000]
    for e in (100, 300, 1000, 3000):
        ax.plot(xs, [e * x / 1000 for x in xs], color=GRID, lw=1, ls=(0, (4, 3)), zorder=1)
        xe = min(11000, 10500 * 1000 / e)
        ax.text(xe, e * xe / 1000, f"{e} Kbps/LUT ", color=MUTED, fontsize=7.5, ha="right", va="bottom",
                rotation=0, bbox=dict(facecolor=SURF, edgecolor="none", pad=0.5))
    if sweep:
        ax.scatter([p["luts"] for p in sweep], [p["thr_pt_long"] for p in sweep], s=14, color=GRID,
                   edgecolor=AXIS, linewidth=0.6, label="design-space sweep (brody/gen)", zorder=2)
    fin = [g for g in gmu if g["impl"] != "Elephant_GMU"]
    ax.scatter([g["luts"] for g in fin], [g["thr_pt_long"] for g in fin], s=30, color=MUTED, edgecolor=SURF,
               linewidth=1, label="other LWC finalists (GMU benchmark)", zorder=3)
    for g in fin:
        if g["impl"] in ("Ascon-128a_GMU2-x2", "Xoodyak_GMU2-x1", "TinyJAMBU_TJT", "Ascon-128_GMU2-x1"):
            ax.annotate(g["impl"], (g["luts"], g["thr_pt_long"]), xytext=(-5, 0), textcoords="offset points",
                        ha="right", va="center", fontsize=7, color=MUTED)
    eg = next((g for g in gmu if g["impl"] == "Elephant_GMU"), None)
    if eg:
        ax.scatter(eg["luts"], eg["thr_pt_long"], marker="*", s=150, color=INK, edgecolor=SURF, linewidth=0.8,
                   label="Elephant_GMU", zorder=5)
        ax.annotate("Elephant_GMU", (eg["luts"], eg["thr_pt_long"]), xytext=(8, -2), textcoords="offset points",
                    fontsize=8, color=INK, fontweight="bold", va="center")
    refs = [c for c in REFS if c in bench]
    ax.scatter([bench[c]["luts"] for c in refs], [bench[c]["thr_pt_long"] for c in refs], s=38, color=C1,
               edgecolor=SURF, linewidth=1, label="base_rN (R = 1, 5, 8, 16)", zorder=4)
    for c in refs:
        ax.annotate(f"R={c.split('_r')[1]}", (bench[c]["luts"], bench[c]["thr_pt_long"]), xytext=(6, -6),
                    textcoords="offset points", fontsize=7.5, color=INK2)
    st = steps_in(bench)
    px = [bench[c]["luts"] for c, _, _ in st]
    py = [bench[c]["thr_pt_long"] for c, _, _ in st]
    ax.plot(px, py, color=C2, lw=1.2, zorder=4)
    ax.scatter(px, py, marker="D", s=44, color=C2, edgecolor=SURF, linewidth=1, label="optimization path", zorder=5)
    for (c, s, _), x, y in zip(st, px, py):
        if c in ("brody/r4_BtoE", "brody/r4_BtoI"):
            continue                 # same place as +F / +J: labeled together
        off = {"brody/base": (8, -11), "brody/base_r4": (-6, -11), "brody/r4_BtoH": (-10, -7), FINAL: (-10, 8),
               "brody/r4_BtoG": (7, -2)}
        dx, dy = off.get(c, (7, -4))
        txt = {"brody/base": "base", "brody/r4_BtoF": "+E, +F", FINAL: "+I, +J"}.get(c, s)
        ax.annotate(txt, (x, y), xytext=(dx, dy), textcoords="offset points",
                    fontsize=8, color=INK, fontweight="bold", ha="right" if dx < 0 else "left")
    if R2 in bench:
        ax.scatter(bench[R2]["luts"], bench[R2]["thr_pt_long"], marker="D", s=44, facecolor=SURF, edgecolor=C2,
                   linewidth=1.5, label="+L at 2 rounds per stage (J + K, L)", zorder=5)
    logan_points(ax, bench, "luts", "thr_pt_long",
                 {"logan/r4": (7, -10, "left"), "logan/pipe16x1d16": (7, -7, "left"),
                  "logan/pipe10x2d8": (7, -4, "left"), "logan/pipe20x2d16": (22, -9, "left", True)})
    logan_opt_points(ax, bench, "luts", "thr_pt_long",
                     {"merged/pipe20x2d16_I": (8, -7, "left"), "merged/pipe20x2d16_IL": (8, 6, "left"),
                      "merged/pipe16x2d16_ILN": (-8, 3, "right"), "merged/pipe10x2d8_IL": (7, 2, "left")})
    ax.set_xlim(500, 12000)
    ax.set_ylim(100, 12000)
    ticks = [500, 1000, 2000, 5000, 10000]
    ax.set_xticks(ticks)
    ax.set_xticklabels([f"{t:,}" for t in ticks])
    yt = [100, 200, 500, 1000, 2000, 5000, 10000]
    ax.set_yticks(yt)
    ax.set_yticklabels([f"{t:,}" for t in yt])
    ax.minorticks_off()
    ax.set_xlabel("LUTs (log scale)")
    ax.set_ylabel("long-message plaintext throughput, Mbit/s (log scale)")
    ax.set_title("Throughput vs area: our cores, Logan's, the sweep and GMU's LWC finalist benchmark")
    ax.legend(loc="lower right", fontsize=8)
    footer(fig, "All on xc7a100tftg256-2L. Finalists: ePrint 2023/484 Tables 12 and 14 (unprotected, "
                "encryption). Diagonals: constant throughput per LUT.")
    save(fig, "05_pareto_all.png")


def g15_thr_luts(bench, gmu):
    """Linear-axis companion to 05: only the optimization path and GMU's finalists, every point of ours
    labeled. On linear axes, constant throughput per LUT is a ray from the origin."""
    fig, ax = plt.subplots(figsize=(10, 6.6))
    X1, Y1 = 8200, 8600
    for e in (500, 1000, 2000, 3000):
        xe = min(X1, Y1 * 1000 / e)
        ax.plot([0, xe], [0, e * xe / 1000], color=GRID, lw=1, ls=(0, (4, 3)), zorder=1)
        yl = {3000: 0.95, 2000: 0.79, 1000: 0.88}.get(e, 0.97) * Y1    # stagger the two steep rays' labels
        xl = min(X1 * 0.985, yl * 1000 / e)
        ax.text(xl, e * xl / 1000, f"{e:,} Kbps/LUT", color=MUTED, fontsize=7.5, ha="right", va="bottom",
                bbox=dict(facecolor=SURF, edgecolor="none", pad=0.5), zorder=1)
    fin = [g for g in gmu if g["impl"] != "Elephant_GMU"]
    ax.scatter([g["luts"] for g in fin], [g["thr_pt_long"] for g in fin], s=30, color=MUTED, edgecolor=SURF,
               linewidth=1, label="other LWC finalists (GMU benchmark)", zorder=3)
    named = {"Ascon-128a_GMU2-x2": (-6, 0, "right"), "Xoodyak_GMU2-x1": (-6, 0, "right"),
             "Ascon-128_GMU2-x2": (-6, 0, "right"), "SPARKLE_GMU2": (6, 0, "left"),
             "AESGCM_GMU-v1": (6, 0, "left"), "TinyJAMBU_TJT": (6, 0, "left")}
    for g in fin:
        if g["impl"] in named:
            dx, dy, ha = named[g["impl"]]
            ax.annotate(g["impl"], (g["luts"], g["thr_pt_long"]), xytext=(dx, dy), textcoords="offset points",
                        ha=ha, va="center", fontsize=7, color=MUTED)
    eg = next((g for g in gmu if g["impl"] == "Elephant_GMU"), None)
    if eg:
        ax.scatter(eg["luts"], eg["thr_pt_long"], marker="*", s=150, color=INK, edgecolor=SURF, linewidth=0.8,
                   label="Elephant_GMU", zorder=5)
        ax.annotate(f"Elephant_GMU\n{eg['thr_pt_long']:.0f} Mbps, {eg['luts']:.0f} LUT",
                    (eg["luts"], eg["thr_pt_long"]), xytext=(9, -4), textcoords="offset points",
                    fontsize=7.5, color=INK, fontweight="bold", ha="left", va="center")
    st = steps_in(bench)
    px = [bench[c]["luts"] for c, _, _ in st]
    py = [bench[c]["thr_pt_long"] for c, _, _ in st]
    ax.plot(px, py, color=C2, lw=1.2, zorder=4)
    ax.scatter(px, py, marker="D", s=44, color=C2, edgecolor=SURF, linewidth=1, label="our optimization path",
               zorder=5)
    off = {"brody/base": (8, -9, "left"), "brody/base_r4": (-8, 0, "right"), "brody/r4_B": (-3, 9, "right"),
           "brody/r4_BtoC": (8, -3, "left"), "brody/r4_BtoD": (8, -4, "left"), "brody/r4_BtoF": (8, -6, "left"),
           "brody/r4_BtoG": (-2, -15, "center"), "brody/r4_BtoH": (-9, -5, "right"),
           FINAL: (-9, 6, "right")}
    for (c, s, m), x, y in zip(st, px, py):
        if c in ("brody/r4_BtoE", "brody/r4_BtoI"):
            continue                 # same place as +F / +J: labeled together
        dx, dy, ha = off.get(c, (8, -4, "left"))
        txt = {"brody/base": "base (R=10)", "brody/base_r4": "base_r4", "brody/r4_BtoF": "+E, +F"}.get(c, s)
        if c == FINAL:
            txt = f"+I, +J  {y:,.0f} Mbps, {x:,.0f} LUT, {1000 * y / x:,.0f} Kbps/LUT"
        ax.annotate(txt, (x, y), xytext=(dx, dy), textcoords="offset points", fontsize=8, color=INK,
                    fontweight="bold", ha=ha, va="center")
    if R2 in bench:
        ax.scatter(bench[R2]["luts"], bench[R2]["thr_pt_long"], marker="D", s=44, facecolor=SURF, edgecolor=C2,
                   linewidth=1.5, label="+L at 2 rounds per stage (J + K, L)", zorder=5)
    logan_points(ax, bench, "luts", "thr_pt_long",
                 {"logan/r4": (4, -16, "right", True), "logan/pipe16x1d16": (8, -2, "left"),
                  "logan/pipe10x2d8": (8, -2, "left"), "logan/pipe20x2d16": (8, -4, "left")})
    logan_opt_points(ax, bench, "luts", "thr_pt_long",
                     {"merged/pipe20x2d16_I": (8, -4, "left"), "merged/pipe20x2d16_IL": (8, 4, "left"),
                      "merged/pipe16x2d16_ILN": (-10, 1, "right"), "merged/pipe10x2d8_IL": (8, 0, "left")},
                     fmt=lambda c, s, x, y: (f"{s}  {y:,.0f} Mbps, {x:,.0f} LUT, {1000 * y / x:,.0f} Kbps/LUT"
                                             if c == "merged/pipe16x2d16_ILN" else s))
    ax.set_xlim(0, X1)
    ax.set_ylim(0, Y1)
    ax.xaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: f"{v:,.0f}"))
    ax.yaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: f"{v:,.0f}"))
    ax.set_xlabel("LUTs")
    ax.set_ylabel("long-message plaintext throughput, Mbit/s")
    ax.set_title("Throughput vs LUTs: our optimization path, Logan's cores and GMU's LWC finalists")
    ax.legend(loc="lower right", fontsize=8)
    footer(fig, "All on xc7a100tftg256-2L, 32-bit LWC API. Finalists: ePrint 2023/484 Tables 12 and 14 "
                "(unprotected, encryption). Dashed rays: constant throughput per LUT.")
    save(fig, "15_thr_vs_luts.png")


def g06_msgsize(bench, gmu):
    sizes = [("thr_pt_16", "16 B"), ("thr_pt_64", "64 B"), ("thr_pt_1536", "1536 B"), ("thr_pt_long", "long")]
    ours = [(c, col) for c, col in (("brody/base", C1), ("brody/r4_BtoF", C2), (FINAL, C3), (R2, C4))
            if c in bench]
    fig, ax = plt.subplots(figsize=(9, 5.6))
    ax.set_yscale("log")
    x = range(len(sizes))
    ends = []
    ctx = [g for g in gmu if g["impl"] in ("Elephant_GMU", "Ascon-128a_GMU2-x2")]
    for g in ctx:
        ys = [g[k] for k, _ in sizes]
        ax.plot(x, ys, color=MUTED if g["impl"] != "Elephant_GMU" else INK2, lw=1.4, ls=(0, (4, 3)), marker="o",
                ms=5, zorder=2, label=f"{g['impl']} (GMU)")
        ends.append((ys[-1], g["impl"], INK2))
    for c, col in ours:
        ys = [bench[c][k] for k, _ in sizes]
        ax.plot(x, ys, color=col, lw=2, marker="o", ms=7, mec=SURF, mew=1.5, zorder=3, label=nice(c))
        ends.append((ys[-1], nice(c), INK))
    import math
    ly = spread([math.log10(v) for v, _, _ in ends], 0.085)
    for (v, name, col), l in zip(ends, ly):
        ax.annotate(name, (len(sizes) - 1, v), xytext=(len(sizes) - 0.88, 10 ** l), textcoords="data",
                    fontsize=8, color=col, va="center",
                    arrowprops=dict(arrowstyle="-", color=AXIS, lw=0.6, shrinkA=0, shrinkB=3))
    ax.set_xticks(list(x))
    ax.set_xticklabels([s for _, s in sizes])
    ax.set_xlim(-0.2, len(sizes) + 0.9)
    yt = [50, 100, 200, 500, 1000, 2000, 5000]
    ax.set_yticks(yt)
    ax.set_yticklabels([f"{t:,}" for t in yt])
    ax.minorticks_off()
    ax.grid(axis="x", visible=False)
    ax.set_xlabel("plaintext message size (no AD)")
    ax.set_ylabel("plaintext throughput, Mbit/s (log scale)")
    ax.set_title("Throughput vs message size")
    ax.legend(loc="upper left", fontsize=8)
    footer(fig, "Short messages are bound by the chain of dependent permutation calls (key, keystream, final), "
                "not by bandwidth. GMU values: ePrint 2023/484 Table 12.")
    save(fig, "06_thr_vs_msgsize.png")


def g16_logan_msgsize(bench):
    """Our two fastest cores against Logan's two fastest, PT throughput by message size. Owner = hue
    (ours orange, Logan aqua), configuration = line style and marker fill; every line directly labeled."""
    sizes = [("thr_pt_16", "16 B"), ("thr_pt_64", "64 B"), ("thr_pt_1536", "1536 B"), ("thr_pt_long", "long")]
    series = [(FINAL, "r4_BtoJ (ours)", C2, "D", "-", True),
              (R2, "r2_BtoL (ours)", C2, "D", (0, (4, 3)), False),
              ("logan/pipe20x2d16", "Logan 20×2 ring", CL, "s", "-", True),
              ("merged/pipe16x2d16_ILN", "Logan ring, 16×2 with 2 entry points + our I, L", CL, "s", (0, (4, 3)),
               False)]
    series = [s for s in series if s[0] in bench]
    if not any(c.startswith(("logan/", "merged/")) for c, *_ in series):
        return
    import math
    fig, ax = plt.subplots(figsize=(9, 5.6))
    ax.set_yscale("log")
    x = list(range(len(sizes)))
    ends, starts = [], []
    if "brody/base" in bench:
        ys = [bench["brody/base"][k] for k, _ in sizes]
        ax.plot(x, ys, color=INK2, lw=1.4, ls=(0, (2, 2)), marker="o", ms=5, zorder=2, label="base (baseline)")
        ends.append((ys[-1], "base (baseline)", INK2))
    for c, name, col, mk, ls, filled in series:
        ys = [bench[c][k] for k, _ in sizes]
        ax.plot(x, ys, color=col, lw=2, ls=ls, marker=mk, ms=7, mfc=col if filled else SURF, mec=col if not filled
                else SURF, mew=1.5, zorder=3, label=name)
        ends.append((ys[-1], name, INK))
        starts.append(ys[0])
    for v, l in zip(starts, spread([math.log10(v) for v in starts], 0.045)):   # 16 B values, nudged apart
        ax.annotate(f"{v:.0f}", (0, v), xytext=(-0.12, 10 ** l), textcoords="data", ha="right", va="center",
                    fontsize=7.5, color=INK2)
    ly = spread([math.log10(v) for v, _, _ in ends], 0.07)
    for (v, name, col), l in zip(ends, ly):
        ax.annotate(name, (len(sizes) - 1, v), xytext=(len(sizes) - 0.88, 10 ** l), textcoords="data",
                    fontsize=8, color=col, va="center",
                    arrowprops=dict(arrowstyle="-", color=AXIS, lw=0.6, shrinkA=0, shrinkB=3))
    ax.set_xticks(x)
    ax.set_xticklabels([s for _, s in sizes])
    ax.set_xlim(-0.55, len(sizes) + 1.3)
    yt = [100, 200, 500, 1000, 2000, 5000]
    ax.set_yticks(yt)
    ax.set_yticklabels([f"{t:,}" for t in yt])
    ax.minorticks_off()
    ax.grid(axis="x", visible=False)
    ax.set_xlabel("plaintext message size (no AD)")
    ax.set_ylabel("plaintext throughput, Mbit/s (log scale)")
    ax.set_title("Our fastest cores vs Logan's 20×2 ring, and his ring with our changes")
    ax.legend(loc="lower right", fontsize=8, handlelength=4)
    footer(fig, "Same flow for all: LWC_TB cycles x Fmax from Vivado 2026.1 on xc7a100tftg256-2L, same wrapper. "
                "Logan's rings win on long messages (higher clock);\nours win on short ones: each permutation call "
                "takes a full trip around his ring (80/K + 1 cycles). Left labels: 16 B throughput.")
    save(fig, "16_logan_msgsize.png")


def g07_ranked(bench, gmu):
    mine = [c for c, _, _ in steps_in(bench)] + ([R2] if R2 in bench else [])
    items = [(g["kbps_per_lut_pt"], g["impl"], "gmu") for g in gmu]
    items += [(bench[c]["kbps_per_lut_pt"], nice(c) + " (ours)", "hero" if c == FINAL else "ours")
              for c in mine]
    items += [(bench[c]["kbps_per_lut_pt"], nice(c), "logan") for c, _, _ in logan_in(bench)]
    items += [(bench[c]["kbps_per_lut_pt"], nice(c), "logan") for c, *_ in LOGAN_OPT if c in bench]
    items.sort()
    fig, ax = plt.subplots(figsize=(8.5, 0.23 * len(items) + 1.2))
    col = {"gmu": CONTEXT, "ours": C1, "hero": C2, "logan": CL}
    y = range(len(items))
    ax.barh(list(y), [v for v, _, _ in items], color=[col[k] for _, _, k in items], height=0.72,
            edgecolor=SURF, linewidth=1, zorder=2)
    for i, (v, name, k) in enumerate(items):
        ax.text(v + 15, i, f"{v:.0f}", va="center", fontsize=7, color=INK if k != "gmu" else INK2)
    ax.set_yticks(list(y))
    ax.set_yticklabels([n for _, n, _ in items], fontsize=7.5)
    for t, (_, n, k) in zip(ax.get_yticklabels(), items):
        if k != "gmu" or n == "Elephant_GMU":
            t.set_color(INK)
            t.set_fontweight("bold")
    ax.set_ylim(-0.7, len(items) - 0.3)
    ax.grid(axis="y", visible=False)
    ax.tick_params(axis="y", length=0)
    ax.set_xlabel("long-message PT throughput / area (Kbit/s per LUT)")
    ax.set_title("Throughput per LUT: our cores and Logan's among GMU's LWC finalist benchmark")
    ax.legend(handles=patches([("GMU benchmark (ePrint 2023/484 Table 14)", CONTEXT), ("our cores", C1),
                               ("r4_BtoJ (final)", C2)] + ([("Logan's cores", CL)] if logan_in(bench) else [])),
              loc="lower right", fontsize=8)
    save(fig, "07_efficiency_ranked.png")


# ---------------------------------------------------------------------------------------------- 9-14: evidence
def g09_breakdown(bench, prof):
    st = [s for s in steps_in(bench) if s[0] in prof]
    if R2 in prof:
        st.append((R2, "+L", "at 2 rounds/stage"))
    st += [(c, s, m) for c, s, m in LOGAN if c in prof]
    if "merged/pipe20x2d16_IL" in prof:
        st.append(("merged/pipe20x2d16_IL", "Logan 20×2", "+ our I, L"))
    if "merged/pipe16x2d16_ILN" in prof:
        st.append(("merged/pipe16x2d16_ILN", "Logan 16×2,", "2 entry points + I, L"))
    segs = [("busy_io_pct", "permutation and I/O overlap", C1, "#ffffff"),
            ("busy_pct", "permutation only", LIGHTBLUE, INK),
            ("io_pct", "I/O only", C2, "#ffffff"),
            ("neither_pct", "idle", GRID, INK2)]
    fig, ax = plt.subplots(figsize=(9.5, 0.48 * len(st) + 1.6))
    for i, (c, s, m) in enumerate(st):
        left = 0
        for key, _, col, tcol in segs:
            v = float(prof[c][key])
            ax.barh(i, v, left=left, color=col, height=0.66, edgecolor=SURF, linewidth=2, zorder=2)
            if v >= 7:
                ax.text(left + v / 2, i, f"{v:.0f}%", ha="center", va="center", fontsize=7.5, color=tcol)
            left += v
        ax.text(101.5, i, f"{int(prof[c]['window_cycles']):,} cycles", va="center", fontsize=7.5, color=INK2)
    ax.set_yticks(range(len(st)))
    ax.set_yticklabels([f"{s} {m.replace(chr(10), ' ')}".strip() if c != "brody/base" else "base" for c, s, m in st],
                       fontsize=8)
    ax.invert_yaxis()
    ax.set_xlim(0, 100)
    ax.set_xlabel("share of cycles (%)")
    ax.grid(axis="y", visible=False)
    ax.tick_params(axis="y", length=0)
    ax.legend(handles=patches([(l, c) for _, l, c, _ in segs]), loc="lower center", bbox_to_anchor=(0.5, 1.0),
              ncol=4, fontsize=8)
    ax.set_title("Where the cycles go (1536 B AD + 1536 B PT)", pad=26)
    footer(fig, "make profile WL=long. 'I/O' = a 32-bit word moves in or out of the core. From +G on, the core "
                "computes while a word moves in over 90% of cycles: it is I/O-bound.\n"
                "Logan's rings: 'permutation' = at least one ring stage holds a call (stages rebuilt from accept/fin, "
                "see scripts/profile.py; the 2-entry 16×2 ring has direct per-stage probes).")
    save(fig, "09_cycle_breakdown.png")


def g10_area():
    cores = [c for c in ("brody/r4_BtoG", "brody/r4_BtoH", FINAL, R2)]
    data = {c: util_hier(c) for c in cores}
    data = {c: d for c, d in data.items() if d}
    if not data:
        return
    parts = [("rounds", "rounds (permutation logic)", C1), ("datapath", "datapath around the rounds", C2),
             ("lfsr", "mask LFSRs", C3), ("control", "control (issue engine, loader)", C4),
             ("wrapper", "LWC wrapper", CONTEXT)]
    fig, axs = plt.subplots(1, 2, figsize=(10, 5.2), gridspec_kw=dict(wspace=0.32))
    short = {"brody/r4_BtoG": "+G", "brody/r4_BtoH": "+H", FINAL: "+J", R2: "+L\n2 rounds/stage"}
    labels = [short.get(c, nice(c)) for c in data]
    for ax, unit, title in ((axs[0], "lut", "LUT sites"), (axs[1], "ff", "flip-flops")):
        for i, (c, d) in enumerate(data.items()):
            bottom = 0
            for key, _, col in parts:
                v = d[unit].get(key, 0)
                ax.bar(i, v, bottom=bottom, color=col, width=0.6, edgecolor=SURF, linewidth=2, zorder=2)
                if v > (450 if unit == "lut" else 300):
                    ax.text(i, bottom + v / 2, f"{v:,}", ha="center", va="center", fontsize=7.5,
                            color="#ffffff" if col in (C1, C2) else INK)
                bottom += v
            ax.text(i, bottom + 60, f"{bottom:,}", ha="center", va="bottom", fontsize=8, color=INK,
                    fontweight="bold")
        ax.set_xticks(range(len(data)))
        ax.set_xticklabels(labels, fontsize=8)
        ax.grid(axis="x", visible=False)
        ax.tick_params(axis="x", length=0)
        ax.set_title(title)
    axs[0].axhline(2560, color=INK2, lw=1, ls=(0, (4, 3)), zorder=3)
    axs[0].text(len(data) - 0.55, 2560, "floor for 32 rounds\n(80 sites per round)", fontsize=7, color=INK2,
                va="center", ha="left")
    axs[0].set_xlim(-0.5, len(data) + 0.3)
    fig.legend(handles=patches([(l, c) for _, l, c in parts]), loc="upper center", bbox_to_anchor=(0.5, 1.03),
               ncol=5, fontsize=8, frameon=False)
    fig.suptitle("Where the area goes", x=0.06, y=1.09, ha="left", fontweight="bold", fontsize=12, color=INK)
    footer(fig, "util_hier.rpt (Vivado hierarchical utilization); the stage registers, mask delay line and "
                "keystream FIFO are in 'datapath'. A LUT site holds up to two small LUT cells.")
    save(fig, "10_area_breakdown.png")


def g11_fmax_rps(bench, gmu, sweep):
    fig, ax = plt.subplots(figsize=(9.5, 5.4))
    ax.set_xscale("log", base=2)
    if sweep:
        ax.scatter([p["rps"] for p in sweep], [p["fmax_mhz"] for p in sweep], s=16, color=GRID, edgecolor=AXIS,
                   linewidth=0.6, label="sweep points (brody/gen)", zorder=2)
        best = {}
        for p in sweep:
            best[p["rps"]] = max(best.get(p["rps"], 0), p["fmax_mhz"])
        ks = sorted(best)
        ax.plot(ks, [best[k] for k in ks], color=MUTED, lw=1.2, zorder=2, label="best sweep Fmax at that rps")
    refs = [c for c in ["brody/base"] + REFS + ["brody/base_r4"] if c in bench]
    ax.scatter([bench[c]["rounds"] for c in refs], [bench[c]["fmax_mhz"] for c in refs], s=40, color=C1,
               edgecolor=SURF, linewidth=1, label="base_rN (R rounds per cycle)", zorder=4)
    for c in refs:
        ax.annotate(f"R={int(bench[c]['rounds'])}", (bench[c]["rounds"], bench[c]["fmax_mhz"]), xytext=(6, -3),
                    textcoords="offset points", fontsize=7.5, color=INK2)
    opt = [c for c, _, _ in steps_in(bench) if c not in ("brody/base", "brody/base_r4")] + [c for c in (R2H, R2) if c in bench]
    grp = {}
    for c in opt:                    # spread the cores that share a rounds-per-stage value
        grp.setdefault(bench[c]["rounds"], []).append(c)
    for c in opt:
        g = grp[bench[c]["rounds"]]
        jit = 2 ** ((g.index(c) - (len(g) - 1) / 2) * 0.03)
        ax.scatter(bench[c]["rounds"] * jit, bench[c]["fmax_mhz"], marker="D", s=40, color=C2, edgecolor=SURF,
                   linewidth=1, zorder=5)
        names = {"brody/r4_BtoH": "+H", FINAL: "+I, +J", R2H: "+H (2 rounds/stage)", R2: "+L (2 rounds/stage)",
                 "brody/r4_BtoD": "+D"}
        if c in names:
            name = names[c]
            right = c in ("brody/r4_BtoH", FINAL)
            ax.annotate(name, (bench[c]["rounds"] * jit, bench[c]["fmax_mhz"]),
                        xytext=(7 if right else -7, -12 if c == R2 else 0),
                        textcoords="offset points", fontsize=8, color=INK, fontweight="bold",
                        ha="left" if right else "right", va="center")
    ax.scatter([], [], marker="D", s=40, color=C2, label="optimized cores (B … J)")
    lg = logan_in(bench)
    if lg:                           # nudged right of our cores that share the rounds-per-stage value
        xs = [bench[c]["rounds"] * 2 ** 0.07 for c, _, _ in lg]
        ys = [bench[c]["fmax_mhz"] for c, _, _ in lg]
        ax.scatter(xs, ys, marker="s", s=44, color=CL, edgecolor=SURF, linewidth=1, zorder=6,
                   label="Logan's cores (rounds per ring stage, or R)")
        lab = {"logan/pipe10x2d8": ("Logan 10×2", (7, -6)), "logan/pipe20x2d16": ("Logan 20×2", (7, 6)),
               "logan/pipe16x1d16": ("Logan 16×1", (7, 0)), "logan/r4": ("Logan R=4", (7, 0))}
        for (c, _, _), x, y in zip(lg, xs, ys):
            name, (dx, dy) = lab.get(c, (c, (7, 0)))
            ax.annotate(name, (x, y), xytext=(dx, dy), textcoords="offset points", fontsize=8, color=INK,
                        fontweight="bold", ha="left", va="center",
                        bbox=dict(facecolor=SURF, edgecolor="none", pad=0.5))
    eg = next((g for g in gmu if g["impl"] == "Elephant_GMU"), None)
    if eg:
        ax.scatter(1, eg["fmax_mhz"], marker="*", s=150, color=INK, edgecolor=SURF, linewidth=0.8, zorder=5,
                   label="Elephant_GMU (1 round per cycle)")
    ax.set_xticks([1, 2, 4, 8, 16])
    ax.set_xticklabels(["1", "2", "4", "8", "16"])
    ax.minorticks_off()
    ax.set_xlabel("rounds per pipeline stage (log scale)")
    ax.set_ylabel("Fmax (MHz)")
    lo = [c for c, *_ in LOGAN_OPT if c in bench]
    if lo:                           # Logan's rings with our changes, right of his base points (all 2 rounds/stage)
        xs = [bench[c]["rounds"] * 2 ** 0.07 for c in lo]
        ys = [bench[c]["fmax_mhz"] for c in lo]
        ax.scatter(xs, ys, marker="s", s=44, facecolor=SURF, edgecolor=CL, linewidth=1.6, zorder=6,
                   label="Logan's rings with our changes (I, L; 32-round ring)")
        ax.annotate(f"Logan's rings + our changes\n{min(ys):.0f}–{max(ys):.0f} MHz", (max(xs), max(ys)),
                    xytext=(9, 2), textcoords="offset points", fontsize=8, color=INK, fontweight="bold",
                    ha="left", va="bottom", bbox=dict(facecolor=SURF, edgecolor="none", pad=0.5))
    ax.set_ylim(40, 265)
    ax.set_title("Clock vs rounds per stage")
    ax.legend(loc="lower left", fontsize=8)
    footer(fig, "Above ~4 rounds per stage the rounds set the clock; below it the control logic and the frozen "
                "LWC wrapper do. +H is handshake-bound at both 4 and 2 rounds/stage; +I registers the handshake.")
    save(fig, "11_fmax_vs_rps.png")


def g12_nks():
    rows = read_csv(REP / "nks_study.csv")
    if not rows:
        return
    fig, ax = plt.subplots(figsize=(7.5, 4.6))
    groups = {}
    for r in rows:
        groups.setdefault(r["rounds_per_stage"], []).append((int(r["nks"]), float(r["cyc_blk_pt_1536"]),
                                                            r["note"]))
    hline(ax, 5, "bus limit (5)", va="top", side="left")
    for (rps, pts), col in zip(sorted(groups.items(), key=lambda kv: -int(kv[0])), (C1, C2)):
        pts.sort()
        name = {"4": "4 rounds per stage (+G, +H)", "2": "2 rounds per stage (+H variant)"}.get(rps, rps)
        ax.plot([p[0] for p in pts], [p[1] for p in pts], color=col, lw=2, marker="o", ms=7, mec=SURF, mew=1.5,
                label=name, zorder=3)
        for n, v, note in pts:
            if "built" in note:
                ax.annotate("built", (n, v), xytext=(0, 9), textcoords="offset points", ha="center", fontsize=7.5,
                            color=INK2)
    ax.set_xlabel("keystream FIFO depth NKS (keystream calls issued ahead)")
    ax.set_ylabel("PT cycles per block (1536 B)")
    ax.set_ylim(0, 11)
    ax.set_xticks(range(3, 13))
    ax.set_title("Keystream run-ahead needed to reach the bus limit")
    ax.legend(loc="upper right", fontsize=8)
    footer(fig, "A keystream call takes ~23 (4 rounds/stage) or ~43 cycles (2 rounds/stage) from issue to result, "
                "so it must start that many blocks early.")
    save(fig, "12_nks_sensitivity.png")


KINDS = [("011", "keystream", C1), ("010", "MAC", C2), ("001", "AD", C3), ("000", "key", C4),
         ("100", "final", "#e87ba4")]


def read_vcd_vec(path, wanted):
    """Per rising clock edge, the value of each wanted signal just before the edge, as a bit string.
    `wanted` maps a key to a signal path below /LWC_TB/uut (bit-blasted vectors are joined, MSB first)."""
    codes, scope, bits = {}, [], {}
    f = open(path)
    for line in f:
        tok = line.split()
        if not tok:
            continue
        if tok[0] == "$scope":
            scope.append(tok[2])
        elif tok[0] == "$upscope":
            scope.pop()
        elif tok[0] == "$var":
            code, name = tok[3], tok[4]
            idx = int(tok[5][1:-1]) if len(tok) > 6 and tok[5].startswith("[") else None
            full = "/".join(scope + [name]).lower()
            for k, w in wanted.items():
                if full.endswith(w.lower()):
                    codes.setdefault(code, []).append((k, idx))
                    if idx is not None:
                        bits.setdefault(k, set()).add(idx)
        elif tok[0] == "$enddefinitions":
            break
    cur = {k: ({i: "x" for i in bits[k]} if k in bits else "x") for k in wanted}
    out, pend = [], []

    def snap():
        return {k: ("".join(v[i] for i in sorted(v, reverse=True)) if isinstance(v, dict) else v)
                for k, v in cur.items()}

    def apply():
        rise = any(k == "clk" and v == "1" for k, _, v in pend) and cur["clk"] == "0"
        if rise:
            out.append(snap())
        for k, i, v in pend:
            if i is None:
                cur[k] = v
            else:
                cur[k][i] = v

    for line in f:
        line = line.strip()
        if not line:
            continue
        if line[0] == "#":
            apply()
            pend = []
        elif line[0] in "01xzXZ" and len(line) > 1:
            pend += [(k, i, line[0].lower()) for k, i in codes.get(line[1:], ())]
        elif line[0] in "bB":
            val, code = line[1:].split()
            pend += [(k, i, val) for k, i in codes.get(code, ())]
    apply()
    return out


def g13_timeline():
    core = "brody/r4_BtoH"
    base = ROOT / "build" / "sim" / "questa" / core
    need = "b_kind"
    vcds = {wl: base / f"prof_{wl}" / "prof.vcd" for wl in ("short", "long")}
    if not all(v.exists() and need in v.read_text()[:20000] for v in vcds.values()):
        print(f"skip 13_slot_timeline.png: needs prof_short / prof_long VCDs with b_v, b_p, b_kind "
              f"(see reports/graphs/README.md)")
        return
    wanted = {"clk": "uut/clk", "b_v": "Inst_Cipher/b_v", "b_p": "Inst_Cipher/b_p", "b_kind": "Inst_Cipher/b_kind",
              "iv": "Inst_Cipher/bdi_valid", "ir": "Inst_Cipher/bdi_ready", "kv": "Inst_Cipher/key_valid",
              "kr": "Inst_Cipher/key_ready", "ov": "Inst_Cipher/bdo_valid", "or": "Inst_Cipher/bdo_ready"}
    PC, NST = 20, 4                                   # cycles per call, stages per ring

    def calls(rows):
        out = []
        for i, v in enumerate(rows):
            if v["b_v"] == "1" and "x" not in v["b_p"]:
                t0 = i + 1                            # loaded at edge i, computes in cycles i+1 .. i+PC
                out.append((t0, int(v["b_p"], 2) // NST, t0 % NST, v["b_kind"]))
        return out

    panels = []
    rows = read_vcd_vec(vcds["short"], wanted)
    act = [i for i, v in enumerate(rows) if v["b_v"] == "1" or (v["iv"] == "1" and v["ir"] == "1")
           or (v["kv"] == "1" and v["kr"] == "1") or (v["ov"] == "1" and v["or"] == "1")]
    # first message of the short workload: up to the first tag word out after a final call
    lo = act[0]
    cl = calls(rows)
    fin = [c[0] for c in cl if c[3] == "100"]
    hi = (fin[0] + PC + 8) if fin else act[-1] + 1
    panels.append(("16 B AD + 16 B PT, one message from the first input word", rows, lo, hi))
    rows = read_vcd_vec(vcds["long"], wanted)
    n, start = 0, None
    for i, v in enumerate(rows):
        n += v["iv"] == "1" and v["ir"] == "1"
        if n >= 480 and start is None:
            start = i
    panels.append(("long message, steady state in the plaintext (a 20 B block every 5 cycles)", rows, start,
                   start + 80))
    fig, axs = plt.subplots(2, 1, figsize=(11, 8.4), gridspec_kw=dict(hspace=0.45))
    lanes = [(r, s) for r in range(2) for s in range(NST)]
    for ax, (title, rows, lo, hi) in zip(axs, panels):
        for t0, ring, res, kind in calls(rows):
            if t0 + PC <= lo or t0 >= hi:
                continue
            j = lanes.index((ring, res))
            y = len(lanes) + 1 - j
            name, col = next(((nm, c) for k, nm, c in KINDS if k == kind), (kind, MUTED))
            ax.broken_barh([(t0 - lo, PC)], (y - 0.36, 0.72), facecolor=col, edgecolor=SURF, linewidth=1.5)
            mid = max(t0, lo) + (min(t0 + PC, hi) - max(t0, lo)) / 2 - lo
            if min(t0 + PC, hi) - max(t0, lo) >= 8:
                ax.text(mid, y, name, ha="center", va="center", fontsize=7,
                        color="#ffffff" if col in (C1, C2) else INK)
        for y, key_v, alt in ((1, ("iv", "ir"), ("kv", "kr")), (0, ("ov", "or"), None)):
            ticks = [(i - lo, 1) for i in range(lo, hi) if (rows[i][key_v[0]] == "1" and rows[i][key_v[1]] == "1")
                     or (alt and rows[i][alt[0]] == "1" and rows[i][alt[1]] == "1")]
            ax.broken_barh(ticks, (y - 0.3, 0.6), facecolor=INK2 if y else MUTED, edgecolor=SURF, linewidth=0.6)
        ax.set_yticks([len(lanes) + 1 - j for j in range(len(lanes))] + [1, 0])
        ax.set_yticklabels([f"ring {'ab'[r]}, slot {s}" for r, s in lanes] + ["word in", "word out"], fontsize=7.5)
        ax.axhline(1.5, color=AXIS, lw=0.8)
        ax.set_xlim(0, hi - lo)
        ax.set_ylim(-0.7, len(lanes) + 1.7)
        ax.grid(axis="y", visible=False)
        ax.tick_params(axis="y", length=0)
        ax.set_title(title, fontsize=10)
        ax.set_xlabel("clock cycle")
    axs[0].legend(handles=patches([(nm, c) for _, nm, c in KINDS]), loc="lower center", bbox_to_anchor=(0.5, 1.13),
                  ncol=5, fontsize=8)
    fig.suptitle("r4_BtoH: every permutation call, by kind", x=0.06, y=0.995, ha="left", fontweight="bold",
                 fontsize=12, color=INK)
    footer(fig, "Each bar is one call: 20 cycles × 4 rounds, moving one stage per cycle around its ring, so a ring "
                "holds 4 calls ('slots'). One call can start per cycle. From Questa VCDs of make profile with "
                "b_v / b_p / b_kind added.")
    save(fig, "13_slot_timeline.png")


def g14_noise():
    runs = read_csv(REP / "synth_runs.csv")
    sets = [("brody/r4_BtoG", "r4_BtoG", ""), ("brody/r4_BtoH", "r4_BtoH", H_NOISE_SINCE)]
    fig, axs = plt.subplots(1, 2, figsize=(10, 4.4), sharey=True, gridspec_kw=dict(wspace=0.08))
    for ax, (core, name, since) in zip(axs, sets):
        rs = [r for r in runs if r["core"] == core and r["date"] >= since]
        if not rs:
            continue
        met = [r for r in rs if r["met"] == "1"]
        bad = [r for r in rs if r["met"] != "1"]
        ax.axhline(0, color=INK2, lw=1)
        ax.scatter([float(r["period_ns"]) for r in met], [float(r["wns_ns"]) for r in met], s=50, color=C1,
                   edgecolor=SURF, linewidth=1, zorder=3, label="met")
        ax.scatter([float(r["period_ns"]) for r in bad], [float(r["wns_ns"]) for r in bad], s=50, facecolor=SURF,
                   edgecolor=C2, linewidth=1.6, zorder=3, label="failed")
        seen = []
        for r in sorted(met, key=lambda r: float(r["period_ns"])):
            if r["period_ns"] in seen:
                continue
            seen.append(r["period_ns"])
            j = len(seen) - 1
            ax.annotate(f"{float(r['fmax_est_mhz']):.1f} MHz", (float(r["period_ns"]), float(r["wns_ns"])),
                        xytext=(0, 8 if j % 2 == 0 else 16), textcoords="offset points", ha="center", fontsize=7,
                        color=INK2)
        reps = {}
        for r in rs:
            reps.setdefault(r["period_ns"], []).append(r)
        for p, rr in reps.items():
            if len(rr) > 1:
                ax.annotate(f"×{len(rr)} identical", (float(p), float(rr[0]["wns_ns"])), xytext=(0, -13),
                            textcoords="offset points", ha="center", fontsize=7, color=MUTED)
        ax.set_title(name)
        ax.set_xlabel("target clock period (ns)")
    axs[0].set_ylabel("worst negative slack (ns)")
    axs[0].legend(loc="lower right", fontsize=8)
    fig.suptitle("Fmax search runs: slack does not grow monotonically with the target period", x=0.06, y=1.02,
                 ha="left", fontweight="bold", fontsize=12, color=INK)
    footer(fig, "reports/synth_runs.csv, final RTL only. A looser target can fail where a tighter one met; "
                "re-running the same target reproduces the result exactly, so every reported Fmax is a closed run.")
    save(fig, "14_synth_noise.png")


# ---------------------------------------------------------------------------------------------- main
def main():
    bench = load_bench()
    if "brody/base" not in bench:
        sys.exit("reports/benchmark.csv has no brody/base row: run `make report` first")
    gmu = load_gmu()
    prof = load_profile()
    try:
        sweep, _ = ps.load("baseline")
    except SystemExit:
        sweep = []
    g01_cycles(bench)
    g02_throughput(bench)
    g03_fmax_area(bench, gmu)
    g04_efficiency(bench, gmu)
    g05_pareto(bench, gmu, sweep)
    g06_msgsize(bench, gmu)
    g07_ranked(bench, gmu)
    g08_ad_vs_pt(bench)
    g09_breakdown(bench, prof)
    g10_area()
    g11_fmax_rps(bench, gmu, sweep)
    g12_nks()
    g13_timeline()
    g14_noise()
    g15_thr_luts(bench, gmu)
    g16_logan_msgsize(bench)


if __name__ == "__main__":
    main()
