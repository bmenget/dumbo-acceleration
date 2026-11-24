# Design-space sweep

Results of `scripts/sweep.py`: one row per design point of the parameterized core
[rtl/brody/gen/](../../rtl/brody/gen/README.md). It's kept apart from `reports/benchmark.csv`, which
covers the named cores, but the metric columns are computed by the same code (`scripts/metrics.py`), so
named cores and sweep points can go on the same plots.

| File | One row per |
|---|---|
| `sweep.csv` | design point and sweep tag |
| `sweep_runs.csv` | Vivado run (the Fmax search history of each point) |

## Running
```sh
source ./setup.sh vivado                       # Questa + Vivado
python3 scripts/sweep.py --tag baseline --R 1-16 --S 1-4 --U 1,2,4,8 --dry-run   # list points
python3 scripts/sweep.py --tag baseline --R 1-16 --S 1-4 --U 1,2,4,8 --jobs 4
python3 scripts/sweep.py --tag fastloader --fast 1 --R 4,8,16 --S 1,2,4 --U 2,4
```

**Which points run:**
- **Skipped:** points where S doesn't divide R (unequal pipeline stages).
- **Size limits:** `--max-n` caps the calls in flight (U·S; off by default). `--max-luts` skips points whose
  *estimated* LUT count is over the limit (default 75% of the device's 63,400). The estimate is
  887 + 165·U·R + 346·N, fitted within ±9% on the synthesized cores, which only go up to N=4. On the full
  grid it peaks at about 33k (U=8, R=16, S=4), so by default nothing is skipped. `--dry-run` prints each
  point's estimate, and `luts_est` sits next to `luts` in every row so the estimate can be checked.
- **Vivado timeout:** a run longer than `--vivado-timeout` hours (default 3) is killed and the point is
  recorded as `error`.
- **RTL snapshot:** at startup, `rtl/brody/gen`, `rtl/shared/lwc` and `tb` are copied to
  `build/sweep/snapshot/<rtl_hash>/`, and every point is built from that copy. Editing the RTL while a
  sweep runs can't mix versions. Run one sweep at a time.
- **Resume:** a point already in `sweep.csv` with the same `tag`, configuration and `rtl_hash` is skipped,
  so an interrupted sweep picks up where it stopped. `--force` re-runs it.
- **Order:** cheapest points first.

**Per point, `sweep.py`:**
1. writes the core into `build/sweep/work/<point>/` (with the configuration constants set);
2. runs the `edge` and `cycles` vector sets;
3. synthesizes, with the Fmax search of `scripts/fmax.py` (probe predicted from R/S and N, at most
   `--max-iter` runs, default 4);
4. classifies the critical path;
5. appends the row.

**What's kept afterwards:**
- **The most recent point:** its folder replaces `build/sweep/last/`.
- **Points that fail** validation or synthesis go to `build/sweep/failed/<point>/` instead.
- **Both keep** RTL, logs and reports. The compiled Questa library is deleted.
- **Everything else is removed.** No per-point RTL or builds are saved.

**Validation level:** `edge` covers block-boundary lengths for AD and plaintext, encryption and
decryption. `cycles` (timing mode) also checks every output and includes 1536 B messages, so it exercises
multi-batch scheduling at large N. Validate a chosen point further with the full `make sim-all` on a
named copy.

## sweep.csv columns
| Column | Meaning |
|---|---|
| `date`, `tag`, `rtl_hash` | When, which sweep, and a hash of `rtl/brody/gen`, `rtl/shared/lwc` and `tb` (rows from older RTL keep their old hash) |
| `point` | `r<R>s<S>u<U>`, plus `f` with the fast loader |
| `R`, `S`, `U`, `fast_loader` | Configuration |
| `rps`, `N`, `M`, `perm_cycles`, `tail_rounds`, `rot`, `nmask` | Derived: rounds per stage, calls in flight, message blocks per round, cycles per call, rounds in the last pass, result offset, masks in the LFSR window (see README.md) |
| `luts_est` | The size-limit estimate (compare with `luts`) |
| `status` | `ok`, `ok_nosynth` (`--no-synth`), `sim_fail`, or `error: …` |
| `edge_pass`, `cycles_pass` | 1 if the vector set passed |
| `fmax_mhz`, `closed`, `best_period_ns`, `wns_ns`, `synth_runs` | Fmax search result, as in `reports/synth_results.csv` (`closed` = 0: no run met timing; Fmax is the best achieved delay, an estimate) |
| `luts`, `ffs`, `slices`, `bram_tiles`, `dsps` | Area |
| `thr_*`, `pct_long_*`, `ad_pt_ratio`, `kbps_per_lut_*`, `x_*`, `cyc_*` | Same definitions as `reports/benchmark.csv` (see `reports/README.md`); `x_` columns are relative to `brody/base_r10` |
| `crit_class` | Category of the worst path (below) |
| `crit_src`, `crit_dst` | Its source and destination registers, shortened (`core/` = CryptoCore, `dp/` = datapath) |
| `crit_levels`, `crit_route_pct` | Logic levels; share of the delay spent in routing |
| `crit_perm_frac` | Share of the path's logic cells inside a permutation stage |
| `crit_2nd`, `crit_3rd` | The next two *distinct* categories, from the worst path to each of up to 1000 endpoints (`paths.tsv`, written by `vivado_build.tcl`). The 5 detailed paths in `timing.rpt` are usually bits of one bus. |
| `crit_2nd_gap_pct`, `crit_3rd_gap_pct` | How much the clock period could shrink (%) before that category becomes critical. Near 0 means two bottlenecks are tied: fixing the worst alone gains nothing. |
| `part`, `vivado`, `runtime_s` | FPGA part, Vivado version, wall time for the point |

## Critical-path categories (`scripts/critpath.py`)
| Category | Meaning |
|---|---|
| `perm` | Most of the path's logic is inside a permutation stage: the clock is set by rounds per stage |
| `ctrl->datapath` | FSM / counter / loader flag → mux selects or enables → a datapath register |
| `core->wrapper` | Core handshake, `bdo` or tag-compare logic → a Pre/PostProcessor register |
| `wrapper`, `wrapper->core` | Inside the frozen LWC wrapper, or from it into the core |
| `tag`, `lfsr` | Ends in the tag accumulator / the mask LFSR |
| `ctrl`, `datapath`, `datapath->ctrl` | The remaining endpoint combinations |

`critpath.py` also works on named cores: `python3 scripts/critpath.py --core brody/r4_BtoD`.
