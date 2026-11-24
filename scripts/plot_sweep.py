#!/usr/bin/env python3
"""Graphs of the design-space sweep (reports/sweep/sweep.csv) into reports/sweep/graphs/.

Uses the rows of one sweep tag (default `baseline`) with status `ok` and the most common rtl_hash of that
tag; named cores from reports/benchmark.csv are overlaid where they compare directly.

  python3 scripts/plot_sweep.py [--tag baseline]      # needs matplotlib

Graphs:
  pareto_thr_vs_luts.png    long-message throughput vs LUTs, Pareto front labeled, named cores overlaid
  fmax_vs_rps.png           Fmax vs rounds per pipeline stage, colored by critical-path class
  efficiency_heatmap.png    kbps/LUT for every (R, S) cell, one panel per U
  throughput_vs_n.png       long- and 16 B-message throughput vs calls in flight N
  lut_model.png             luts_est (sweep.py's size estimate) vs synthesized LUTs
"""
import argparse
import csv
from collections import Counter
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.colors import LinearSegmentedColormap  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SWEEP = ROOT / "reports" / "sweep" / "sweep.csv"
BENCH = ROOT / "reports" / "benchmark.csv"
OUT = ROOT / "reports" / "sweep" / "graphs"

# palette: light surface, recessive chrome, one blue ramp for ordered values, orange as the contrast hue
SURF, INK, INK2, MUTED, GRID, AXIS = "#fcfcfb", "#0b0b0b", "#52514e", "#898781", "#e1e0d9", "#c3c2b7"
BLUE, ORANGE = "#2a78d6", "#eb6834"
U_COLORS = {1: "#86b6ef", 2: "#3987e5", 4: "#1c5cab", 8: "#0d366b"}   # ordinal blue, light -> dark
SEQ = LinearSegmentedColormap.from_list("seq", ["#cde2fb", "#9ec5f4", "#5598e7", "#256abf", "#104281"])
NAMED = {"brody/base": "base (baseline)", "brody/r4_BtoC": "r4_BtoC", "brody/r4_BtoD": "r4_BtoD", "brody/r4_BtoE": "r4_BtoE"}

plt.rcParams.update({
    "figure.facecolor": SURF, "axes.facecolor": SURF, "savefig.facecolor": SURF,
    "axes.edgecolor": AXIS, "axes.labelcolor": INK2, "axes.titlecolor": INK, "axes.titleweight": "bold",
    "axes.titlesize": 12, "axes.titlelocation": "left", "axes.labelsize": 10,
    "xtick.color": MUTED, "ytick.color": MUTED, "xtick.labelcolor": INK2, "ytick.labelcolor": INK2,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6, "axes.axisbelow": True,
    "axes.spines.top": False, "axes.spines.right": False, "legend.frameon": False,
    "legend.fontsize": 9, "font.size": 9, "text.color": INK,
})


def fnum(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def load(tag):
    rows = [r for r in csv.DictReader(open(SWEEP)) if r["tag"] == tag and r["status"] == "ok"]
    if not rows:
        raise SystemExit(f"no ok rows for tag {tag!r} in {SWEEP}")
    h = Counter(r["rtl_hash"] for r in rows).most_common(1)[0][0]
    pts = {}
    for r in rows:
        if r["rtl_hash"] != h:
            continue
        p = {k: (int(r[k]) if k in ("R", "S", "U", "N", "rps", "luts", "luts_est") else fnum(r[k]))
             for k in ("R", "S", "U", "N", "rps", "luts", "luts_est", "fmax_mhz", "thr_pt_long", "thr_pt_16",
                       "kbps_per_lut_pt", "x_thr_pt_long", "crit_perm_frac")}
        p["point"], p["crit"] = r["point"], r["crit_class"]
        pts[r["point"]] = p                     # latest row of a point wins
    return list(pts.values()), h


def load_named():
    if not BENCH.exists():
        return []
    out = []
    for r in csv.DictReader(open(BENCH)):
        if r["core"] in NAMED and fnum(r["luts"]) and fnum(r["thr_pt_long"]):
            out.append(dict(name=NAMED[r["core"]], luts=fnum(r["luts"]), thr=fnum(r["thr_pt_long"]),
                            thr16=fnum(r["thr_pt_16"]), fmax=fnum(r["fmax_mhz"])))
    return out


def pareto(pts, x, y):
    """Points not beaten on both axes (smaller x, larger y)."""
    front, best = [], -1
    for p in sorted(pts, key=lambda p: (p[x], -p[y])):
        if p[y] > best:
            front.append(p)
            best = p[y]
    return front


def footer(fig, text):
    fig.text(0.01, 0.005, text, color=MUTED, fontsize=7.5, ha="left", va="bottom")


def save(fig, name):
    OUT.mkdir(parents=True, exist_ok=True)
    fig.savefig(OUT / name, dpi=160, bbox_inches="tight")
    plt.close(fig)
    print(f"wrote {OUT / name}")


# ---------------------------------------------------------------------------------------------- graphs
def plot_pareto(pts, named, src):
    fig, ax = plt.subplots(figsize=(10, 6.2))
    xmax = max(p["luts"] for p in pts) * 1.06
    # iso-efficiency guides (kbps per LUT)
    ymax = max(p["thr_pt_long"] for p in pts) * 1.1
    for e in (100, 200, 300, 400):
        ax.plot([0, xmax], [0, e * xmax / 1000], color=GRID, lw=1, ls=(0, (4, 3)), zorder=1)
        xe = min(xmax * 0.99, ymax * 0.97 * 1000 / e)
        ax.text(xe, e * xe / 1000, f" {e} kbps/LUT", color=MUTED, fontsize=7.5, ha="left", va="center",
                bbox=dict(facecolor=SURF, edgecolor="none", pad=1))
    for u, c in U_COLORS.items():
        sel = [p for p in pts if p["U"] == u]
        ax.scatter([p["luts"] for p in sel], [p["thr_pt_long"] for p in sel], s=34, color=c,
                   edgecolor=SURF, linewidth=1, label=f"U = {u}", zorder=3)
    front = pareto(pts, "luts", "thr_pt_long")
    ax.plot([p["luts"] for p in front], [p["thr_pt_long"] for p in front], color=INK2, lw=1.4, zorder=2,
            label="Pareto front (sweep)")
    last = None        # label the front sparsely so labels don't collide
    for p in front:
        if last and p["thr_pt_long"] - last["thr_pt_long"] < 280:
            continue
        ax.annotate(p["point"], (p["luts"], p["thr_pt_long"]), xytext=(-6, 2), textcoords="offset points",
                    fontsize=7.5, color=INK, ha="right", va="bottom")
        last = p
    for n in named:
        ax.scatter(n["luts"], n["thr"], marker="D", s=40, color=ORANGE, edgecolor=SURF, linewidth=1, zorder=4)
        ax.annotate(n["name"], (n["luts"], n["thr"]), xytext=(7, -3), textcoords="offset points",
                    fontsize=7.5, color=INK2, fontweight="bold", va="center")
    if named:
        ax.scatter([], [], marker="D", s=40, color=ORANGE, label="named cores (benchmark.csv)")
    ax.set_xlim(0, xmax)
    ax.set_ylim(0, ymax)
    ax.set_xlabel("LUTs")
    ax.set_ylabel("Long-message plaintext throughput (Mbit/s)")
    ax.set_title("Throughput vs area: the Pareto front of the sweep")
    ax.legend(loc="lower right")
    footer(fig, src + "   ·   dashed: constant efficiency")
    save(fig, "pareto_thr_vs_luts.png")
    return front


def plot_fmax(pts, src):
    fig, ax = plt.subplots(figsize=(10, 5.6))
    groups = [("perm-limited (critical path in a permutation stage)", BLUE, lambda p: p["crit"] == "perm"),
              ("control / wrapper / tag-limited", ORANGE, lambda p: p["crit"] != "perm")]
    for label, c, f in groups:
        sel = [p for p in pts if f(p)]
        # spread overlapping points at one rps a little by N so they stay visible
        xs = [p["rps"] + (p["N"].bit_length() - 3) * 0.06 for p in sel]
        ax.scatter(xs, [p["fmax_mhz"] for p in sel], s=34, color=c, edgecolor=SURF, linewidth=1,
                   label=label, zorder=3)
    # best Fmax per rps
    by = {}
    for p in pts:
        by[p["rps"]] = max(by.get(p["rps"], 0), p["fmax_mhz"])
    ks = sorted(by)
    ax.plot(ks, [by[k] for k in ks], color=INK2, lw=1.2, zorder=2, label="best Fmax at that rps")
    ax.set_xticks(range(1, max(ks) + 1))
    ax.set_xlabel("Rounds per pipeline stage  (R / S)")
    ax.set_ylabel("Fmax (MHz)")
    ax.set_ylim(0, max(p["fmax_mhz"] for p in pts) * 1.12)
    ax.set_title("Fmax is set by rounds per stage once it exceeds ~5")
    ax.legend(loc="upper right")
    footer(fig, src + "   ·   points at one rps are spread slightly by N")
    save(fig, "fmax_vs_rps.png")


def plot_heatmap(pts, src):
    us = sorted({p["U"] for p in pts})
    Rs = list(range(1, max(p["R"] for p in pts) + 1))
    Ss = sorted({p["S"] for p in pts})
    vmax = max(p["kbps_per_lut_pt"] for p in pts)
    vmin = min(p["kbps_per_lut_pt"] for p in pts)
    best = max(pts, key=lambda p: p["kbps_per_lut_pt"])
    fig, axes = plt.subplots(len(us), 1, figsize=(11, 1.2 + 1.25 * len(us) * len(Ss) / 2.2), sharex=True)
    cell = {(p["U"], p["R"], p["S"]): p for p in pts}
    for ax, u in zip(axes, us):
        ax.grid(False)
        ax.set_facecolor(SURF)
        for s in Ss:
            for r in Rs:
                p = cell.get((u, r, s))
                if p is None:
                    face, txt = ("#f0efec" if r % s == 0 else SURF), ("–" if r % s == 0 else "")
                    ax.add_patch(plt.Rectangle((r - 0.5, s - 0.5), 1, 1, facecolor=face, edgecolor=SURF, lw=2))
                    ax.text(r, s, txt, ha="center", va="center", color=MUTED, fontsize=7)
                    continue
                v = p["kbps_per_lut_pt"]
                t = (v - vmin) / (vmax - vmin)
                ax.add_patch(plt.Rectangle((r - 0.5, s - 0.5), 1, 1, facecolor=SEQ(t), edgecolor=SURF, lw=2))
                ax.text(r, s, f"{v:.0f}", ha="center", va="center", fontsize=7.5,
                        color="#ffffff" if t > 0.55 else INK)
                if p is best:
                    ax.add_patch(plt.Rectangle((r - 0.46, s - 0.46), 0.92, 0.92, fill=False,
                                               edgecolor=ORANGE, lw=2))
        ax.set_xlim(0.5, len(Rs) + 0.5)
        ax.set_ylim(max(Ss) + 0.5, 0.5)
        ax.set_yticks(Ss)
        ax.set_ylabel(f"U = {u}\nstages S", rotation=0, ha="right", va="center", labelpad=8)
        for sp in ax.spines.values():
            sp.set_visible(False)
        ax.tick_params(length=0)
    axes[-1].set_xticks(Rs)
    axes[-1].set_xlabel("Rounds per unit R")
    axes[0].set_title(f"Efficiency (long-message kbps per LUT) across the grid   ·   best: {best['point']}"
                      f" = {best['kbps_per_lut_pt']:.0f} (outlined)")
    footer(fig, src + "   ·   blank: S does not divide R (not built)   ·   –: build failed or not run")
    save(fig, "efficiency_heatmap.png")


def plot_vs_n(pts, named, src):
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(11, 4.8), sharex=True)
    Ns = sorted({p["N"] for p in pts})
    v2 = next((n for n in named if n["name"].startswith("v2 ")), None)
    for ax, key, ref, title in ((a1, "thr_pt_long", "thr", "Long messages"),
                                (a2, "thr_pt_16", "thr16", "16-byte messages")):
        for u, c in U_COLORS.items():
            sel = [p for p in pts if p["U"] == u]
            ax.scatter([p["N"] for p in sel], [p[key] for p in sel], s=30, color=c, edgecolor=SURF,
                       linewidth=1, label=f"U = {u}", zorder=3)
        best = {}
        for p in pts:
            best[p["N"]] = max(best.get(p["N"], 0), p[key])
        ax.plot(Ns, [best[n] for n in Ns], color=INK2, lw=1.2, zorder=2, label="best at that N")
        if v2:
            ax.axhline(v2[ref], color=ORANGE, lw=1.2, ls=(0, (4, 3)), zorder=2)
            ax.text(Ns[-1], v2[ref], "v2 baseline", color=INK2, fontsize=7.5, ha="right", va="bottom")
        ax.set_xscale("log", base=2)
        ax.set_xticks(Ns)
        ax.set_xticklabels([str(n) for n in Ns])
        ax.set_ylim(0, max(p[key] for p in pts) * 1.12)
        ax.set_xlabel("Calls in flight  N = U · S")
        ax.set_title(title)
    a1.set_ylabel("Plaintext throughput (Mbit/s)")
    a1.legend(loc="upper left")
    fig.suptitle("More calls in flight helps long messages and costs short ones", x=0.01, ha="left",
                 fontweight="bold", fontsize=12, color=INK)
    fig.tight_layout(rect=(0, 0.03, 1, 1))
    footer(fig, src)
    save(fig, "throughput_vs_n.png")


def plot_lut_model(pts, src):
    fig, ax = plt.subplots(figsize=(6.4, 6))
    m = max(max(p["luts"], p["luts_est"]) for p in pts) * 1.05
    ax.fill_between([0, m], [0, m * 0.91], [0, m * 1.09], color="#f0efec", zorder=1, label="±9 % (fit range)")
    ax.plot([0, m], [0, m], color=AXIS, lw=1, zorder=2)
    for u, c in U_COLORS.items():
        sel = [p for p in pts if p["U"] == u]
        ax.scatter([p["luts_est"] for p in sel], [p["luts"] for p in sel], s=30, color=c, edgecolor=SURF,
                   linewidth=1, label=f"U = {u}", zorder=3)
    err = sorted(100 * (p["luts"] / p["luts_est"] - 1) for p in pts)
    lo, hi = min(pts, key=lambda p: p["luts"] / p["luts_est"]), max(pts, key=lambda p: p["luts"] / p["luts_est"])
    ax.text(0.98, 0.03, f"synth / estimate − 1\nmedian {err[len(err) // 2]:+.0f} %\n"
            f"min {err[0]:+.0f} % ({lo['point']})\nmax {err[-1]:+.0f} % ({hi['point']})",
            transform=ax.transAxes, ha="right", va="bottom", fontsize=8, color=INK2, linespacing=1.5)
    ax.set_xlim(0, m)
    ax.set_ylim(0, m)
    ax.set_aspect("equal")
    ax.set_xlabel("Estimated LUTs (sweep.py luts_estimate)")
    ax.set_ylabel("Synthesized LUTs")
    ax.set_title("LUT estimate vs synthesis")
    ax.legend(loc="upper left")
    footer(fig, src)
    save(fig, "lut_model.png")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tag", default="baseline")
    a = ap.parse_args()
    pts, h = load(a.tag)
    named = load_named()
    src = f"sweep.csv · tag {a.tag} · rtl {h} · {len(pts)} points · xc7a100t-2L"
    front = plot_pareto(pts, named, src)
    plot_fmax(pts, src)
    plot_heatmap(pts, src)
    plot_vs_n(pts, named, src)
    plot_lut_model(pts, src)
    print("Pareto front:", ", ".join(f"{p['point']} ({p['luts']} LUT, {p['thr_pt_long']:.0f} Mbps)" for p in front))


if __name__ == "__main__":
    main()
