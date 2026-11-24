# Design-space sweep

`scripts/sweep.py` runs the parameterized core [rtl/brody/gen/](../../rtl/brody/gen/README.md) over a grid of
R (rounds of logic per unit), S (pipeline stages per unit), U (units) and the fast loader. Each point is
generated, validated, synthesized and its critical path classified. Metric columns are computed by the same code
as `reports/benchmark.csv` (`scripts/metrics.py`), so sweep points and named cores can share a plot.

| File | One row per |
|---|---|
| `sweep.csv` | design point and sweep tag |
| `sweep_runs.csv` | Vivado run (each point's Fmax search) |
| `graphs/` | `python3 scripts/plot_sweep.py`: Pareto front, Fmax vs rounds per stage, efficiency heatmap, LUT model |

## Findings (tag `baseline`: 111 points, R 1–16, S 1–4, U 1/2/4/8, fast loader off)
- **Fmax falls with rounds per stage:** best 232 MHz at 1, 195 at 4, 95 at 10, 60 at 16.
- **Best points:** throughput r8s4u4 (4384 Mbps, 13.3k LUT, 330 Kbps/LUT); efficiency r4s1u8
  (467 Kbps/LUT, 4186 Mbps); 16 B messages r5s1u2 (297 Mbps).
- **Efficiency is capped at about 470 Kbps/LUT**, the same plateau as `brody/r4_BtoD`–`F`. `brody/gen` keeps D's
  lockstep batches, where more slots buy throughput only with matching area. Every named core from G on beats every
  sweep point on long-message throughput and Kbps/LUT; the staggered, stage-0-loaded design is what broke the cap.
- **Critical path:** `perm` on 62 points, `wrapper->core` 25, `ctrl->datapath` 15, `tag` 9.

## Running
```sh
source ./setup.sh vivado                                                         # Questa + Vivado
python3 scripts/sweep.py --tag baseline --R 1-16 --S 1-4 --U 1,2,4,8 --dry-run   # list points and LUT estimates
python3 scripts/sweep.py --tag baseline --R 1-16 --S 1-4 --U 1,2,4,8 --jobs 4
python3 scripts/sweep.py --tag fastloader --fast 1 --R 4,8,16 --S 1,2,4 --U 2,4
```
- **Skipped points:** S must divide R. `--max-n` caps calls in flight (U·S); `--max-luts` skips points whose
  estimated LUTs (887 + 165·U·R + 346·N, ±9%) exceed a limit (default 75% of the device, which nothing on the
  full grid reaches).
- **Per point:** generate the core in `build/sweep/work/<point>/`, run the `edge` and `cycles` sets, synthesize
  (`scripts/fmax.py` search, `--max-iter` 4), classify the critical path, append the row. Vivado runs longer
  than `--vivado-timeout` hours (default 3) are killed and recorded as `error`.
- **Reproducible and resumable:** the RTL is snapshotted at startup (editing it mid-sweep can't mix versions; run
  one sweep at a time). A point already in `sweep.csv` with the same tag, configuration and `rtl_hash` is
  skipped, so an interrupted sweep resumes; `--force` re-runs it. Cheapest points run first.
- **Disk:** only the most recent point (`build/sweep/last/`) and failed points (`build/sweep/failed/`) are kept.
- **Validation level:** `edge` and `cycles` cover block boundaries, encrypt and decrypt, and 1536 B messages. Run
  the full `make sim-all` on a named copy before relying on a point.

## sweep.csv columns
| Column | Meaning |
|---|---|
| `date`, `tag`, `rtl_hash` | When, which sweep, and a hash of the RTL it was built from |
| `point` | `r<R>s<S>u<U>`, plus `f` with the fast loader |
| `R`, `S`, `U`, `fast_loader` | Configuration |
| `rps`, `N`, `M`, `perm_cycles`, `tail_rounds`, `rot`, `nmask` | Derived values (see `rtl/brody/gen/README.md`) |
| `luts_est` | The size-limit estimate, to compare with `luts` |
| `status` | `ok`, `ok_nosynth` (`--no-synth`), `sim_fail`, or `error: …` |
| `edge_pass`, `cycles_pass` | 1 if the set passed |
| `fmax_mhz`, `closed`, `best_period_ns`, `wns_ns`, `synth_runs` | As in `reports/synth_results.csv` |
| `luts`, `ffs`, `slices`, `bram_tiles`, `dsps` | Area |
| `thr_*`, `pct_long_*`, `ad_pt_ratio`, `kbps_per_lut_*`, `x_*`, `cyc_*` | As in `reports/benchmark.csv` |
| `crit_class`, `crit_src`, `crit_dst` | Category of the worst path and its endpoints (`core/` = CryptoCore, `dp/` = datapath) |
| `crit_levels`, `crit_route_pct`, `crit_perm_frac` | Logic levels, routing share of the delay, share of logic inside a permutation stage |
| `crit_2nd`, `crit_3rd`, `*_gap_pct` | The next two *distinct* categories, and how much the period could shrink (%) before each becomes critical. Near 0 = tied bottlenecks: fixing the worst alone gains nothing |
| `part`, `vivado`, `runtime_s` | FPGA part, Vivado version, wall time |

## Critical-path categories
`scripts/critpath.py` (also for named cores: `python3 scripts/critpath.py --core brody/r4_BtoD`).

| Category | Meaning |
|---|---|
| `perm` | Most of the path's logic is inside a permutation stage: rounds per stage set the clock |
| `ctrl->datapath` | FSM / counter / loader flag → mux selects or enables → a datapath register |
| `core->wrapper` | Core handshake, `bdo` or tag compare → a Pre/PostProcessor register |
| `wrapper`, `wrapper->core` | Inside the frozen LWC wrapper, or from it into the core |
| `tag`, `lfsr` | Ends in the tag accumulator or the mask LFSR |
| `ctrl`, `datapath`, `datapath->ctrl` | The remaining combinations |
