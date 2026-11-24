#!/usr/bin/env python3
"""Final-report graphs. Writes PNGs into reports/graphs/.

  python3 scripts/plot_report.py            # needs matplotlib; `make plots`

Inputs (all already in the repo):
  reports/benchmark.csv        make report: one row per named core
  reports/gmu_published.csv    GMU's unprotected results, ePrint 2023/484 Tables 12 + 14 (docs/SCA-Benchmarking.pdf)
  reports/profile.csv          make profile WL=long: where the cycles go
  reports/sweep/sweep.csv      design-space sweep of brody/gen (optional)

Figures:
  01_landscape.png         throughput vs LUTs (linear): every core we built against Elephant_GMU, Pareto front
  01b_long_vs_short.png    long-message vs 16 B throughput, one dot per core: what each core gives up
  02_progress.png          long-message throughput and Kbps/LUT at every step, both lineages
  03_bottleneck.png        cycles per block falling to the 32-bit bus limit, and where the cycles go
  05_unroll.png            R alone (base_rN), with the sweep and Elephant_GMU: Fmax, LUTs, throughput
  07_rankings.png          ranked against GMU's whole field: 16 B throughput, long throughput, throughput per LUT
  07b_rankings_ad.png      the same for associated data: long-message AD throughput and AD throughput per LUT

Color = who built the core, everywhere: Brody's cores orange diamonds, Logan's cores blue squares, merged cores
light green circles (darker green outline). GMU's finalists are gray context; Elephant_GMU is ink.
"""
import csv
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import plot_sweep as ps  # noqa: E402  (sets rcParams: shared look with the sweep graphs)
from plot_sweep import AXIS, GRID, INK, INK2, MUTED, SURF, fnum, plt  # noqa: E402

ROOT = ps.ROOT
REP = ROOT / "reports"
OUT = REP / "graphs"

# categorical slots in fixed order (validated default palette); context marks stay gray
C1, C2, C3, C4 = "#2a78d6", "#eb6834", "#1baf7a", "#eda100"
LIGHTBLUE = "#86b6ef"
DARKBLUE = "#1c5cab"
CONTEXT = "#b9b7ae"

# owner -> (color, marker, legend name)
# light green: OKLab dE x100 vs orange / blue >= 26 normal vision, >= 10 under deutan / protan / tritan simulation.
# Its contrast on the surface is low (1.86), so marks and outlines in it get the darker GREEN_EDGE.
GREEN = "#7ccf6e"
GREEN_EDGE = "#4f9e45"
OWN = {"ours": (C2, "D", "Brody's cores"),
       "logan": (C1, "s", "Logan's cores"),
       "merged": (GREEN, "o", "Merged cores")}


# the r4 optimization path: core, short label, what the step did
STEPS = [
    ("brody/base_r10", "base_r10", "R=10"),
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
FINAL = "brody/r4_BtoJ"
R2 = "brody/r2_BtoL"
R2H = "brody/r2_BtoH"
# the final designs: core, label
FINALS = [
    (FINAL, "r4_BtoJ"),
    (R2, "r2_BtoL"),
    ("merged/ring20_IL", "ring20_IL"),
    ("merged/ring40_IL", "ring40_IL"),
    ("merged/ring32_ILN", "ring32_ILN"),
]
NICE = {c: l for c, l in FINALS}
NICE.update({"brody/base_r10": "base_r10", "logan/r4": "Logan r4", "logan/ring16": "ring16",
             "logan/ring20": "ring20", "logan/ring40": "ring40",
             "merged/ring40_I": "ring40_I", "merged/r2_BtoM": "r2_BtoM"})


def nice(c):
    return NICE.get(c, c.rsplit("/", 1)[-1])


def owner(c):
    return "merged" if c.startswith("merged/") else "logan" if c.startswith("logan/") else "ours"


def ocol(c):
    return OWN[owner(c)][0]


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

def spread(vals, gap):
    """Nudge sorted label positions apart by at least `gap` (same units as vals)."""
    order = sorted(range(len(vals)), key=lambda i: vals[i])
    out = list(vals)
    for a, b in zip(order, order[1:]):
        if out[b] - out[a] < gap:
            out[b] = out[a] + gap
    return out


# ---------------------------------------------------------------------------------------------- 01 landscape
LAND_OURS = ["brody/base_r1", "brody/base_r10", "brody/base_r4", "brody/r4_B", "brody/r4_BtoC", "brody/r4_BtoD", "brody/r4_BtoE",
             "brody/r4_BtoF", "brody/r4_BtoG", "brody/r4_BtoH", "brody/r4_BtoI", "brody/r4_BtoJ", R2H, R2]
LAND_LOGAN = ["logan/r4", "logan/ring16", "logan/ring20", "logan/ring40"]
LAND_MERGED = ["merged/ring40_I", "merged/ring40_IL", "merged/ring32_ILN", "merged/ring20_IL",
               "merged/r2_BtoM"]


def landscape(bench, gmu, key, fname, title, ylabel, lim, rays, near, columns, gap, legend_loc, eg_off=(9, -2, "left")):
    """Every core we have against Elephant_GMU (GMU's own Elephant): throughput (`key`) vs LUTs on linear axes, each
    core labeled by name. Points with room are labeled beside themselves (`near`: core -> dx, dy, ha in points);
    crowded ones from label columns with leader lines (`columns`: x of the text, alignment, cores), label heights
    nudged at least `gap` apart. r4_BtoE and r4_BtoF are one point and share a label. The only line is the Pareto
    front over the designs shown, drawn as a staircase (right, then up). `rays`: (Kbps/LUT, x of its label)."""
    cores = [c for c in LAND_OURS + LAND_LOGAN + LAND_MERGED if c in bench]

    def name(c):
        if c == "brody/r4_BtoE" and "brody/r4_BtoF" in bench:
            return "r4_BtoE / r4_BtoF"
        return {"logan/r4": "Logan r4"}.get(c, c.split("/", 1)[1])

    eg = next((g for g in gmu if g["impl"] == "Elephant_GMU"), None)
    pts = ([dict(x=eg["luts"], y=eg[key])] if eg else []) + [dict(x=bench[c]["luts"], y=bench[c][key]) for c in cores]
    front = ps.pareto(pts, "x", "y")

    fig, ax = plt.subplots(figsize=(11.5, 7.8))
    X1, Y1 = lim
    ax.set_xlim(0, X1)
    ax.set_ylim(0, Y1)
    for e, xl in rays:              # constant Kbps/LUT: rays from the origin, labeled where the plot is empty
        xe = min(X1, Y1 * 1000 / e)
        ax.plot([0, xe], [0, e * xe / 1000], color=GRID, lw=1, ls=(0, (4, 3)), zorder=1)
        p0, p1 = ax.transData.transform([(0, 0), (1000, e)])
        ang = math.degrees(math.atan2(p1[1] - p0[1], p1[0] - p0[0]))
        ax.text(xl, e * xl / 1000, f"{e:,} Kbps/LUT", color=MUTED, fontsize=7.5, ha="center", va="bottom",
                rotation=ang, rotation_mode="anchor", zorder=1)
    # staircase: from each front point, right at its throughput to the next point's LUTs, then up
    ax.step([p["x"] for p in front], [p["y"] for p in front], where="post", color=INK2, lw=1.3, zorder=4,
            label="Pareto front (designs shown)")
    if eg:
        ax.scatter(eg["luts"], eg[key], marker="*", s=190, color=INK, edgecolor=SURF, linewidth=0.8,
                   zorder=8, label="Elephant_GMU (GMU, spec v1, 1 round/cycle)")
        ax.annotate("Elephant_GMU", (eg["luts"], eg[key]), xytext=eg_off[:2], textcoords="offset points",
                    fontsize=8, color=INK, ha=eg_off[2], va="center")
    for kind, group in (("ours", LAND_OURS), ("logan", LAND_LOGAN), ("merged", LAND_MERGED)):
        g = [c for c in group if c in bench]
        col, mk, lab = OWN[kind]
        ax.scatter([bench[c]["luts"] for c in g], [bench[c][key] for c in g], marker=mk,
                   s=56 if mk != "D" else 46, color=col, edgecolor=GREEN_EDGE if kind == "merged" else SURF,
                   linewidth=1, zorder=7, label=lab)

    def xy(c):
        return bench[c]["luts"], bench[c][key]

    for c, (dx, dy, ha) in near.items():
        if c in bench:
            ax.annotate(name(c), xy(c), xytext=(dx, dy), textcoords="offset points", fontsize=8, color=INK, ha=ha,
                        va="center", zorder=8)
    for x_text, ha, group in columns:
        g = [c for c in group if c in bench]
        ys = spread([bench[c][key] for c in g], gap)
        for c, yt in zip(g, ys):
            ax.annotate(name(c), xy(c), xytext=(x_text, yt), textcoords="data", fontsize=8, color=INK, ha=ha,
                        va="center", zorder=8,
                        arrowprops=dict(arrowstyle="-", color=AXIS, lw=0.7, shrinkA=2, shrinkB=4))
    ax.xaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: f"{v:,.0f}"))
    ax.yaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: f"{v:,.0f}"))
    ax.set_xlabel("LUTs")
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.legend(loc=legend_loc, fontsize=8)
    footer(fig, "All on xc7a100tftg256-2L, 32-bit LWC interface, unprotected, encryption. Elephant_GMU: Mohajerani et al., "
                "ePrint 2023/484, Tables 12 and 14.\nDashed rays: constant throughput per LUT. Pareto front: the designs "
                "no other design shown beats on both LUTs and throughput.")
    save(fig, fname)


def f01_landscape(bench, gmu):
    """01: long messages (the 16 B side of the trade-off is 01b)."""
    landscape(
        bench, gmu, "thr_pt_long", "01_landscape.png", "Long messages: every core we built, against Elephant_GMU",
        "long-message plaintext throughput, Mbit/s", (7900, 8900),
        rays=((250, 6900), (500, 6500), (1000, 2500), (1500, 1500)),
        near={"brody/base_r1": (9, -3, "left"),
              "brody/base_r10": (9, 0, "left"), "brody/base_r4": (9, -5, "left"), "brody/r4_B": (0, 13, "center"),
              "brody/r4_BtoC": (-8, 9, "right"), "brody/r4_BtoD": (9, -3, "left"), "logan/r4": (-9, 3, "right"),
              "logan/ring16": (-9, 0, "right"), "logan/ring20": (-9, 0, "right"),
              "merged/ring20_IL": (-9, 3, "right"), "brody/r4_BtoG": (0, -13, "center"),
              "merged/ring32_ILN": (-6, 11, "right"), "brody/r4_BtoE": (9, 3, "left")},
        columns=((4950, "right", ["brody/r4_BtoJ", "brody/r4_BtoH"]),
                 (6250, "left", ["merged/ring40_IL", "merged/ring40_I", "logan/ring40", R2,
                                 "merged/r2_BtoM", R2H, "brody/r4_BtoI"])),
        gap=210, legend_loc="upper left", eg_off=(-9, 0, "right"))


def f01b_long_short(bench, gmu):
    """Every core as one dot: long-message throughput (x) against 16 B throughput (y), so each dot shows both, and
    the trade-off between them is the shape of the chart. LUTs are not shown (01 has them). The only line is the
    Pareto front for the two message sizes (no other core is faster at both), drawn as a staircase. Cores that
    land on the same spot share one label."""
    cores = [c for c in LAND_OURS + LAND_LOGAN + LAND_MERGED if c in bench]
    shared = {"brody/r4_BtoE": ("brody/r4_BtoF", "r4_BtoE / r4_BtoF"),
              "brody/r4_BtoI": ("brody/r4_BtoJ", "r4_BtoI / r4_BtoJ"),
              "merged/ring40_IL": ("merged/ring32_ILN", "ring40_IL /\nring32_ILN")}
    hidden = {other for other, _ in shared.values()}

    def name(c):
        if c in shared and shared[c][0] in bench:
            return shared[c][1]
        return {"logan/r4": "Logan r4"}.get(c, c.split("/", 1)[1])

    eg = next((g for g in gmu if g["impl"] == "Elephant_GMU"), None)
    pts = ([dict(x=eg["thr_pt_long"], y=eg["thr_pt_16"])] if eg else []) + \
          [dict(x=bench[c]["thr_pt_long"], y=bench[c]["thr_pt_16"]) for c in cores]
    front, best = [], -1.0            # maximize both: walk from the right, keep each new best 16 B value
    for p in sorted(pts, key=lambda p: (-p["x"], -p["y"])):
        if p["y"] > best:
            front.append(p)
            best = p["y"]
    front.sort(key=lambda p: p["x"])

    fig, ax = plt.subplots(figsize=(11.5, 7.8))
    ax.set_xlim(0, 8900)
    ax.set_ylim(0, 300)
    # staircase: from each front point, down to the next point's 16 B value, then right to it
    ax.step([p["x"] for p in front], [p["y"] for p in front], where="pre", color=INK2, lw=1.3, zorder=4,
            label="Pareto front (no core is faster at both sizes)")
    if eg:
        ax.scatter(eg["thr_pt_long"], eg["thr_pt_16"], marker="*", s=190, color=INK, edgecolor=SURF, linewidth=0.8,
                   zorder=8, label="Elephant_GMU (GMU, spec v1, 1 round/cycle)")
        ax.annotate("Elephant_GMU", (eg["thr_pt_long"], eg["thr_pt_16"]), xytext=(9, -2), textcoords="offset points",
                    fontsize=8, color=INK, va="center")
    for kind, group in (("ours", LAND_OURS), ("logan", LAND_LOGAN), ("merged", LAND_MERGED)):
        g = [c for c in group if c in bench]
        col, mk, lab = OWN[kind]
        ax.scatter([bench[c]["thr_pt_long"] for c in g], [bench[c]["thr_pt_16"] for c in g], marker=mk,
                   s=56 if mk != "D" else 46, color=col, edgecolor=GREEN_EDGE if kind == "merged" else SURF,
                   linewidth=1, zorder=7, label=lab)
    lead = {"brody/base_r1"}         # sits on Elephant_GMU: labeled from above-right with a leader line
    off = {"brody/base_r1": (34, 22, "left"),
           "brody/base_r10": (9, 0, "left"), "brody/base_r4": (9, 0, "left"), "brody/r4_B": (0, 12, "center"),
           "logan/r4": (9, -3, "left"), "brody/r4_BtoC": (9, 0, "left"), "brody/r4_BtoD": (9, 0, "left"),
           "brody/r4_BtoE": (9, 0, "left"), "logan/ring16": (9, 0, "left"), "logan/ring20": (9, 0, "left"),
           "merged/ring20_IL": (-9, 0, "right"), "brody/r4_BtoG": (0, -12, "center"),
           "brody/r4_BtoH": (-9, 0, "right"), "brody/r4_BtoI": (0, 12, "center"), R2H: (9, 0, "left"),
           R2: (9, 2, "left"), "merged/r2_BtoM": (-9, -2, "right"), "logan/ring40": (-9, 0, "right"),
           "merged/ring40_I": (0, -12, "center"), "merged/ring40_IL": (0, 18, "center")}
    for c in cores:
        if c in hidden or c not in off:
            continue
        dx, dy, ha = off[c]
        ax.annotate(name(c), (bench[c]["thr_pt_long"], bench[c]["thr_pt_16"]), xytext=(dx, dy),
                    textcoords="offset points", fontsize=8, color=INK, ha=ha, va="center", zorder=8,
                    arrowprops=dict(arrowstyle="-", color=AXIS, lw=0.7, shrinkA=2, shrinkB=5) if c in lead else None)
    ax.xaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: f"{v:,.0f}"))
    ax.set_xlabel("long-message plaintext throughput, Mbit/s")
    ax.set_ylabel("16 B plaintext throughput, Mbit/s")
    ax.set_title("Long vs 16 B messages: what each core gives up")
    ax.legend(loc="lower right", fontsize=8)
    footer(fig, "All on xc7a100tftg256-2L, 32-bit LWC interface, unprotected, encryption; 16 B = 16-byte plaintext, no AD. "
                "Elephant_GMU: Mohajerani et al., ePrint 2023/484, Table 12.\nLUTs are not shown here (see 01). "
                "Pareto front: the cores no other core beats at both message sizes. Cores on the same spot share a label.")
    save(fig, "01b_long_vs_short.png")


# ---------------------------------------------------------------------------------------------- 02 speedup sources


# ---------------------------------------------------------------------------------------------- 02 progress
PROGRESS_A = [("brody/base_r1", "base_r1\nR=1\n(ref.)"), ("brody/base_r10", "base_r10\nbaseline")] + \
    [(c, f"{lab}\n{m}") for c, lab, m in STEPS[1:]] + [(R2, "r2_BtoL\nR=2")]
# Logan's cores in groups, each followed by what we built on it: (core, label, starts a new group)
PROGRESS_B = [("logan/r4", "Logan r4\niterative", True), ("logan/ring16", "ring16\n16×1", True),
              ("logan/ring20", "ring20\n10×2", True), ("merged/ring20_IL", "ring20_IL\n+ our I, L", False),
              ("logan/ring40", "ring40\n20×2", True), ("merged/ring40_I", "ring40_I\n+ our I", False),
              ("merged/ring40_IL", "ring40_IL\n+ our L", False), ("merged/ring32_ILN", "ring32_ILN\n+ N", False)]


def f02_progress(bench, gmu):
    """Long-message throughput (top) and Kbps/LUT (bottom) at every step of both lineages: our path from base_r10
    (with base_r1 as the Elephant_GMU-like reference) and Logan's ring40 with our options. Header: speedup over
    base_r10. Elephant_GMU as a reference line in both panels."""
    a = [(c, l) for c, l in PROGRESS_A if c in bench]
    b = [(c, l, g) for c, l, g in PROGRESS_B if c in bench]
    xs, x = list(range(len(a))), len(a) + 0.2
    for i, (_, _, new) in enumerate(b):
        x += 1 + (0.35 if new and i else 0)          # a small gap before each of Logan's groups
        xs.append(x)
    cores = [c for c, _ in a] + [c for c, _, _ in b]
    labels = [l for _, l in a] + [l for _, l, _ in b]
    cols = [INK2 if c.startswith("brody/base_r1") else ocol(c) for c in cores]
    eg = next((g for g in gmu if g["impl"] == "Elephant_GMU"), None)
    base = bench["brody/base_r10"]["thr_pt_long"]
    fig, (ax, a2) = plt.subplots(2, 1, figsize=(17, 8.2), sharex=True,
                                 gridspec_kw=dict(height_ratios=[1.35, 1], hspace=0.08))
    for axis, key, fmt, ylab, egkey in ((ax, "thr_pt_long", "{:,.0f}", "long-message PT throughput, Mbit/s",
                                         "thr_pt_long"),
                                        (a2, "kbps_per_lut_pt", "{:,.0f}", "Kbit/s per LUT", "kbps_per_lut_pt")):
        vals = [bench[c][key] for c in cores]
        axis.bar(xs, vals, width=0.68, color=cols, edgecolor=SURF, linewidth=1, zorder=2)
        top = max(vals)
        for x, v in zip(xs, vals):
            axis.text(x, v + top * 0.012, fmt.format(v), ha="center", va="bottom", fontsize=7.5, color=INK, zorder=5,
                      bbox=dict(facecolor=SURF, edgecolor="none", pad=0.6))
        if eg:
            axis.axhline(eg[egkey], color=INK, lw=1, ls=(0, (4, 3)), zorder=3)
        axis.set_ylim(0, top * 1.16)
        axis.set_ylabel(ylab)
        axis.grid(axis="x", visible=False)
        axis.yaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: f"{v:,.0f}"))
        axis.axvline((xs[len(a) - 1] + xs[len(a)]) / 2, color=AXIS, lw=0.8)
    # header: speedup over base_r10, long-message throughput
    for x, c in zip(xs, cores):
        v = bench[c]["thr_pt_long"] / base
        ax.annotate(f"×{v:.2f}" if v < 0.995 else f"×{v:.1f}" if v < 9.95 else f"×{v:.0f}", (x, 1.0),
                    xycoords=("data", "axes fraction"), xytext=(0, 4), textcoords="offset points", ha="center",
                    va="bottom", fontsize=8, color=INK, fontweight="bold")
    ax.annotate("speedup over\nbase_r10", (-0.62, 1.0), xycoords=("data", "axes fraction"), xytext=(-4, 4),
                textcoords="offset points", ha="right", va="bottom", fontsize=7.5, color=INK2)
    ax.text((len(a) - 1) / 2, 0.97, "Brody's path: base_r10 → r4 options B–J, then r2_BtoL",
            transform=ax.get_xaxis_transform(), ha="center", va="top", fontsize=8.5, color=INK2)
    ax.text(sum(xs[len(a):]) / max(len(b), 1), 0.97, "Logan's cores, each followed by our options on it",
            transform=ax.get_xaxis_transform(), ha="center", va="top", fontsize=8.5, color=INK2)
    a2.set_xticks(xs)
    a2.set_xticklabels(labels, fontsize=7.5)
    a2.tick_params(axis="x", length=0)
    a2.set_xlim(-0.7, xs[-1] + 0.6)
    ref = ([plt.Line2D([], [], color=INK, lw=1, ls=(0, (4, 3)),
                       label=f"Elephant_GMU ({eg['thr_pt_long']:,.0f} Mbit/s, {eg['kbps_per_lut_pt']:,.0f} Kbit/s per LUT)")]
           if eg else [])
    ax.legend(handles=patches([("base_r1 / base_r10 (reference)", INK2)] +
                              [(OWN[k][2], OWN[k][0]) for k in ("ours", "logan", "merged")]) + ref,
              loc="upper left", bbox_to_anchor=(0.0, 0.9), fontsize=8)
    ax.set_title("Progress: throughput and efficiency at every step", pad=22)
    footer(fig, "Long-message plaintext, xc7a100tftg256-2L (Vivado 2026.1, out of context, LWC wrapper included). Each "
                "step on Brody's path includes the ones before it; r2_BtoL is J + K + L at R=2.\nElephant_GMU: "
                "Mohajerani et al., ePrint 2023/484, Tables 12 and 14 (spec v1, 1 round per cycle).")
    save(fig, "02_progress.png")


# ---------------------------------------------------------------------------------------------- 03 bottleneck
def f03_bottleneck(bench, prof):
    rows = [("brody/base_r1", "base_r1 (R=1, as Elephant_GMU)")]
    rows += [(c, f"{s} {m}".replace("\n", " ") if c != "brody/base_r10" else "base_r10 (baseline)") for c, s, m in STEPS]
    rows += [(R2, "r2_BtoL (R=2)"), ("logan/r4", "Logan r4 (iterative, R=4)"), ("logan/ring16", "ring16 (Logan's)"),
             ("logan/ring20", "ring20 (Logan's)"), ("merged/ring20_IL", "ring20_IL"),
             ("logan/ring40", "ring40 (Logan's)"), ("merged/ring40_IL", "ring40_IL"),
             ("merged/ring32_ILN", "ring32_ILN")]
    rows = [(c, l) for c, l in rows if c in bench and c in prof]
    n_ref = sum(1 for c, _ in rows if c == "brody/base_r1")
    n_path = n_ref + sum(1 for c, _ in rows if c in dict((s[0], 1) for s in STEPS))
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(12.5, 0.42 * len(rows) + 2.2), sharey=True,
                                 gridspec_kw=dict(width_ratios=[1, 1.45], wspace=0.04))
    y = list(range(len(rows)))
    pt = [bench[c]["cyc_blk_pt"] for c, _ in rows]
    ad = [bench[c]["cyc_blk_ad"] for c, _ in rows]
    XMAX = 56                         # base_r1 (170 cycles) would squash every other bar: its bar is cut here
    a1.barh(y, [min(v, XMAX) for v in pt], height=0.62, color=[ocol(c) for c, _ in rows], edgecolor=SURF,
            linewidth=1, zorder=2)
    a1.scatter([v for v in ad if v <= XMAX], [i for i, v in zip(y, ad) if v <= XMAX], marker="o", s=22,
               facecolor=SURF, edgecolor=INK, linewidth=1.1, zorder=4, label="associated data")
    for i, v in enumerate(pt):
        if v > XMAX:
            a1.text(XMAX - 1, i, f"bar cut: PT {v:.2f}, AD {ad[i]:.2f}  ▸", ha="right", va="center", fontsize=7.5,
                    color="#ffffff", fontweight="bold", zorder=5)
        else:
            a1.text(max(v, ad[i]) + 0.8, i, f"{v:.2f}", va="center", fontsize=7.5, color=INK)
    a1.axvline(5, color=INK, lw=1.1, ls=(0, (4, 3)), zorder=3)
    a1.text(5.6, -0.95, "32-bit bus limit: 5 cycles per 20 B block", ha="left", va="bottom", fontsize=7.5, color=INK)
    a1.set_xlim(0, XMAX)
    a1.set_xlabel("cycles per 20 B block, long messages")
    a1.grid(axis="y", visible=False)
    a1.tick_params(axis="y", length=0)
    a1.set_yticks(y)
    a1.set_yticklabels([l for _, l in rows], fontsize=8)
    a1.invert_yaxis()
    a1.set_ylim(len(rows) - 0.5, -1.3)
    handles = [plt.Line2D([], [], ls="none", marker="s", ms=8, color=OWN[k][0], label=f"plaintext, {OWN[k][2]}")
               for k in ("ours", "logan", "merged")]
    handles.append(plt.Line2D([], [], ls="none", marker="o", ms=5, mfc=SURF, mec=INK, label="associated data"))
    a1.legend(handles=handles, loc="lower right", fontsize=7.5)
    a1.set_title("Cycles per block")
    segs = [("busy_io_pct", "permutation runs while a word moves", DARKBLUE, "#ffffff"),
            ("busy_pct", "permutation only", LIGHTBLUE, INK),
            ("io_pct", "word moves, permutation idle", "#d5e5f8", INK),
            ("neither_pct", "neither (control, waiting)", GRID, INK2)]
    for i, (c, _) in enumerate(rows):
        left = 0
        for key, _, col, tcol in segs:
            v = float(prof[c][key])
            a2.barh(i, v, left=left, color=col, height=0.62, edgecolor=SURF, linewidth=1.5, zorder=2)
            if v >= 6:
                a2.text(left + v / 2, i, f"{v:.0f}%", ha="center", va="center", fontsize=7.5, color=tcol)
            left += v
    for a in (a1, a2):
        a.axhline(n_path - 0.5, color=AXIS, lw=0.8)
        a.axhline(n_path + 0.5, color=AXIS, lw=0.8)    # Brody's cores above, Logan's and merged below
        if n_ref:
            a.axhline(n_ref - 0.5, color=AXIS, lw=0.8)
    a2.set_xlim(0, 100)
    a2.set_xlabel("share of cycles (%), 1536 B AD + 1536 B PT")
    a2.grid(axis="y", visible=False)
    a2.tick_params(axis="y", length=0, left=False)
    a2.legend(handles=patches([(l, c) for _, l, c, _ in segs]), loc="upper center", bbox_to_anchor=(0.5, -0.07),
              ncol=2, fontsize=7.5)
    a2.set_title("Where the cycles go")
    fig.suptitle("The bottleneck moves from the permutation to the 32-bit bus", x=0.01, y=0.97, ha="left",
                 fontweight="bold", fontsize=12, color=INK)
    footer(fig, "Left: make cycles. Right: make profile WL=long ('word moves' = a 32-bit word enters or leaves the core). "
                "base_r1 computes alone 93% of the time; base_r10 leaves the permutation idle 44% of the time;\nfrom +G "
                "on, a word moves in over 90% of cycles: the core is I/O-bound, and only a faster clock raises "
                "throughput. ring20_IL is still permutation-bound (8.1 cycles).")
    save(fig, "03_bottleneck.png")


# ---------------------------------------------------------------------------------------------- 04 message size


# ---------------------------------------------------------------------------------------------- 05 unroll
def f05_unroll(bench, gmu, sweep):
    """Fmax, LUTs and throughput against R for the base_rN cores (the same core with only the unroll changed), the
    brody/gen design-space sweep (Fmax panel) and Elephant_GMU. No optimized core: this figure is about unrolling."""
    refs = sorted([c for c in ("brody/base_r1", "brody/base_r4", "brody/base_r5", "brody/base_r8", "brody/base_r10",
                               "brody/base_r16") if c in bench], key=lambda c: bench[c]["rounds"])
    eg = next((g for g in gmu if g["impl"] == "Elephant_GMU"), None)
    fig, axs = plt.subplots(1, 3, figsize=(13.5, 4.9), gridspec_kw=dict(wspace=0.28))
    keys = (("fmax_mhz", "Fmax (MHz)", "Clock"), ("luts", "LUTs", "Area"),
            ("thr_pt_long", "long-message PT throughput, Mbit/s", "Throughput"))
    for ax, (k, ylab, title) in zip(axs, keys):
        ax.set_xscale("log", base=2)
        if k == "fmax_mhz" and sweep:
            ax.scatter([p["rps"] for p in sweep], [p["fmax_mhz"] for p in sweep], s=12, color=GRID, edgecolor=AXIS,
                       linewidth=0.5, zorder=2, label="design-space sweep (brody/gen)")
        rx = [bench[c]["rounds"] for c in refs]
        ax.plot(rx, [bench[c][k] for c in refs], color=INK, lw=1.6, marker="o", ms=6, mfc=SURF, mec=INK, mew=1.4,
                zorder=4, label="base_rN: the same core with only the unroll changed")
        if eg:
            ax.scatter(1, eg[k], marker="*", s=150, color=INK2, edgecolor=SURF, linewidth=0.8, zorder=5,
                       label="Elephant_GMU")
        ax.set_xticks([1, 2, 4, 8, 16])
        ax.set_xticklabels(["1", "2", "4", "8", "16"])
        ax.set_xlim(0.75, 21)
        ax.minorticks_off()
        ax.set_xlabel("R")
        ax.set_ylabel(ylab)
        ax.set_title(title)
    axs[0].set_ylim(0, 270)
    axs[1].set_ylim(0, 4500)
    a = axs[2]
    a.set_ylim(0, 700)
    best = max(refs, key=lambda c: bench[c]["thr_pt_long"])
    b = bench["brody/base_r10"]["thr_pt_long"]
    a.annotate(f"unrolling alone:\nat best ×{bench[best]['thr_pt_long'] / b:.2f} over base_r10",
               (bench[best]["rounds"], bench[best]["thr_pt_long"]), xytext=(1.0, 640), textcoords="data",
               ha="left", va="center", fontsize=8, color=INK, arrowprops=dict(arrowstyle="-", color=AXIS, lw=0.7,
                                                                             shrinkB=6))
    axs[0].text(19, 262, "above R ≈ 4\nthe rounds set the clock", ha="right", va="top", fontsize=7.5,
                color=INK2)
    handles, labels = axs[0].get_legend_handles_labels()
    fig.legend(handles, labels, loc="upper center", bbox_to_anchor=(0.5, 1.02), ncol=3, fontsize=8, frameon=False)
    fig.suptitle("Unrolling alone cannot buy throughput: the clock falls as fast as the cycles do", x=0.01, y=1.08,
                 ha="left", fontweight="bold", fontsize=12, color=INK)
    footer(fig, "R = rounds of Spongent-π a permutation call advances per clock cycle: PERM_ROUNDS_PER_CYCLE for base_rN, "
                "the rounds per pipeline stage for the sweep (not brody/gen's own R, rounds per unit).\n"
                "base_rN: brody/base_r10 with only PERM_ROUNDS_PER_CYCLE changed (base_r10 is the baseline; base_r4 did not "
                "close timing at its best target).")
    save(fig, "05_unroll.png")


# ---------------------------------------------------------------------------------------------- 06 family tree


# ---------------------------------------------------------------------------------------------- 07 rankings
def rank_panel(ax, items, fmt, xlabel, title):
    """One ranked bar panel as in 04: items = (value, name, key), key "gmu" for GMU's finalists, else a core."""
    items = sorted(items)
    yy = list(range(len(items)))
    cols = [CONTEXT if k == "gmu" else INK2 if k in ("brody/base_r10", "brody/base_r1") else ocol(k)
            for _, _, k in items]
    ax.barh(yy, [v for v, _, _ in items], height=0.72, color=cols, edgecolor=SURF, linewidth=0.8, zorder=2)
    top = max(v for v, _, _ in items)
    for i, (v, name, k) in enumerate(items):
        ax.text(v + top * 0.01, i, fmt(v), va="center", fontsize=6.5, color=INK if k != "gmu" else INK2)
    ax.set_yticks(yy)
    ax.set_yticklabels([n for _, n, _ in items], fontsize=6.8)
    for t, (_, n, k) in zip(ax.get_yticklabels(), items):
        if k != "gmu" or n == "Elephant_GMU":
            t.set_color(INK)
            t.set_fontweight("bold")
    ax.set_ylim(-0.7, len(items) - 0.3)
    ax.grid(axis="y", visible=False)
    ax.tick_params(axis="y", length=0)
    ax.set_xlim(0, top * 1.14)
    ax.xaxis.set_major_formatter(plt.FuncFormatter(lambda v, _: f"{v:,.0f}"))
    ax.set_xlabel(xlabel)
    ax.set_title(title)


def f07_rankings(bench, gmu):
    """Where our designs rank in GMU's benchmark of the LWC finalists: 16 B throughput, long-message throughput and
    long-message throughput per LUT, each panel ranking all of GMU's unprotected designs plus ours."""
    ours = [c for c in ["brody/base_r1", "brody/base_r10"] + [c for c, _ in FINALS if owner(c) == "merged"]
            if c in bench]
    panels = (("thr_pt_16", lambda v: f"{v:,.0f}", "16 B plaintext throughput, Mbit/s", "16 B messages"),
              ("thr_pt_long", lambda v: f"{v:,.0f}", "long-message plaintext throughput, Mbit/s", "Long messages"),
              ("kbps_per_lut_pt", lambda v: f"{v:,.0f}", "Kbit/s per LUT (long messages)",
               "Throughput per LUT"))
    fig, axs = plt.subplots(1, 3, figsize=(16.5, 8.4), gridspec_kw=dict(wspace=0.62))
    for ax, (key, fmt, xlabel, title) in zip(axs, panels):
        items = [(g[key], g["impl"], "gmu") for g in gmu]
        items += [(bench[c][key], nice(c), c) for c in ours]
        rank_panel(ax, items, fmt, xlabel, title)
    handles = patches([("GMU's finalist designs", CONTEXT), ("base_r1 / base_r10 (reference)", INK2),
                       (OWN["merged"][2], OWN["merged"][0])])
    fig.subplots_adjust(top=0.9)
    fig.legend(handles=handles, loc="upper center", bbox_to_anchor=(0.5, 0.975), ncol=3, fontsize=8, frameon=False)
    fig.suptitle("Where our designs rank among GMU's benchmark of the LWC finalists", x=0.01, y=1.0, ha="left",
                 fontweight="bold", fontsize=12, color=INK)
    footer(fig, "All on xc7a100tftg256-2L, 32-bit LWC interface, unprotected, encryption. GMU values: Mohajerani et al., "
                "ePrint 2023/484, Tables 12 and 14 (Elephant_GMU is spec v1, 1 round per cycle).\nOurs: the merged cores "
                "(ring40_IL, ring32_ILN, ring20_IL), base_r10 (the baseline) and base_r1 (base_r10 at 1 round per "
                "cycle, Elephant_GMU's setting). "
                "16 B = 16-byte plaintext, no AD.")
    save(fig, "07_rankings.png")


def f07b_rankings_ad(bench, gmu):
    """The associated-data side of 07: long-message AD throughput and AD throughput per LUT, GMU's field plus the
    merged cores and the two bases. GMU's long AD throughput = Table 14's AD Kbps/LUT x LUTs (their tables give
    the per-LUT figure, not the throughput itself)."""
    ours = [c for c in ["brody/base_r1", "brody/base_r10"] + [c for c, _ in FINALS if owner(c) == "merged"]
            if c in bench]
    fig, axs = plt.subplots(1, 2, figsize=(11.5, 8.4), gridspec_kw=dict(wspace=0.62))
    items = [(g["kbps_per_lut_ad"] * g["luts"] / 1000, g["impl"], "gmu") for g in gmu]
    items += [(bench[c]["thr_ad_long"], nice(c), c) for c in ours]
    rank_panel(axs[0], items, lambda v: f"{v:,.0f}", "long-message AD throughput, Mbit/s", "Associated data")
    items = [(g["kbps_per_lut_ad"], g["impl"], "gmu") for g in gmu]
    items += [(bench[c]["kbps_per_lut_ad"], nice(c), c) for c in ours]
    rank_panel(axs[1], items, lambda v: f"{v:,.0f}", "Kbit/s per LUT (long AD)", "AD throughput per LUT")
    handles = patches([("GMU's finalist designs", CONTEXT), ("base_r1 / base_r10 (reference)", INK2),
                       (OWN["merged"][2], OWN["merged"][0])])
    fig.subplots_adjust(top=0.9)
    fig.legend(handles=handles, loc="upper center", bbox_to_anchor=(0.5, 0.975), ncol=3, fontsize=8, frameon=False)
    fig.suptitle("Associated data: where our designs rank among GMU's benchmark", x=0.01, y=1.0, ha="left",
                 fontweight="bold", fontsize=12, color=INK)
    footer(fig, "All on xc7a100tftg256-2L, unprotected. GMU values: ePrint 2023/484 Table 14; their long-message AD "
                "throughput is AD Kbps/LUT × LUTs.\nAD needs one permutation call per 20 B block, plaintext two, so "
                "AD runs faster until both reach the 32-bit bus limit (base_r10: AD/PT 1.67; the rings: 0.99).")
    save(fig, "07b_rankings_ad.png")


# ---------------------------------------------------------------------------------------------- appendix


# ---------------------------------------------------------------------------------------------- main
def main():
    bench = load_bench()
    if "brody/base_r10" not in bench:
        sys.exit("reports/benchmark.csv has no brody/base_r10 row: run `make report` first")
    gmu = load_gmu()
    prof = load_profile()
    try:
        sweep, _ = ps.load("baseline")
    except SystemExit:
        sweep = []
    f01_landscape(bench, gmu)
    f01b_long_short(bench, gmu)
    f02_progress(bench, gmu)
    f03_bottleneck(bench, prof)
    f05_unroll(bench, gmu, sweep)
    f07_rankings(bench, gmu)
    f07b_rankings_ad(bench, gmu)


if __name__ == "__main__":
    main()
