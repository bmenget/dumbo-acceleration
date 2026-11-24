# Reports

What each CSV here holds and how it is measured. Every row is keyed by `core`, the core's path under `rtl/`
(naming in [rtl/README.md](../rtl/README.md)). Graphs are in [graphs/](graphs/README.md), the design-space
sweep in [sweep/](sweep/README.md).

| File | Written by | One row per |
|---|---|---|
| `benchmark.csv` | `make report` (rebuilt each run) | core: **the headline comparison** |
| `profile.csv` | `make profile` (replaces that core × workload row) | core × workload |
| `synth_results.csv` | `make synth` (appended) | synthesis of a core (its best run) |
| `synth_runs.csv` | `make synth` (appended) | single Vivado run of the Fmax search |
| `flow_results.csv`, `flow_runs.csv` | `scripts/synth.py --flow tsyn\|perf\|area` | the same, for the Vivado flow study on `brody/r4_BtoI` (not used by `make report`) |
| `nks_study.csv` | by hand | keystream FIFO depth vs cycles per PT block (`brody/r4_BtoG`, `brody/r2_BtoH`) |
| `gmu_published.csv` | parsed from `docs/SCA-Benchmarking.pdf` | GMU's unprotected LWC designs (ePrint 2023/484, Tables 12 and 14) |

**Comparing cores.** `brody/base_r10` is the baseline; the `x_` columns are always relative to it. A core
named `rN_<options>` is built on `brody/base_rN`, so judge its own gain against that row. The `base_rN` cores
are references, not optimizations: `base_r10` at other rounds per cycle (`base_r1` matches GMU's published
`Elephant_GMU`).

## benchmark.csv
Joins each core's measured cycles (`make cycles`) with its latest synthesis (`make synth`). Columns follow GMU's
benchmark tables so our cores line up with `Elephant_GMU`: throughput in **Mbit/s**, efficiency in
**Kbit/s per LUT**. All messages are encryptions with a reused key.

| Column | Meaning |
|---|---|
| `rounds`, `cycles_per_perm` | `PERM_ROUNDS_PER_CYCLE` and 80 / rounds; blank if the core has no single value |
| `fmax_mhz`, `luts`, `ffs` | From the latest synthesis |
| `thr_pt_long` | Long-message plaintext throughput: bits added between 160 B and 1536 B, over the cycles added. Per-message overhead removed (the paper's "Long") |
| `thr_pt_1536`, `thr_pt_64`, `thr_pt_16` | Plaintext-only messages of that size: `8 × bytes × Fmax / cycles` |
| `pct_long_1536`, `_64`, `_16` | That size's throughput as % of long: what per-message overhead costs |
| `thr_ad_long`, `ad_pt_ratio` | Long-message AD-only throughput, and AD / PT (AD needs one permutation per block, PT two) |
| `kbps_per_lut_pt`, `kbps_per_lut_ad` | Long throughput per LUT: was the speedup just bought with area? |
| `x_thr_pt_long`, `x_thr_pt_16`, `x_kbps_per_lut_pt` | This core ÷ `brody/base_r10` (above 1 is better) |
| `cyc_blk_pt`, `cyc_blk_ad` | Steady-state cycles per 20-byte block: architecture speed, independent of Fmax |
| `cyc_pt_16`, `cyc_pt_64`, `cyc_pt_1536` | Raw measured cycles behind the throughputs |
| `part`, `synth_date`, `cycles_date` | Where and when the numbers came from |
| `checks` | Numbers not to trust: `cycles_failed`, `cycles_stale` / `synth_stale` (RTL changed after the measurement), `no_synth`, `other_part`, `not_closed` |

Current flags: `brody/base_r4` is `not_closed` (its search stopped at a loose target), and `brody/gen` is
stale (use `sweep/` for it).

## How each number is measured

**Cycles (`make cycles`).** Runs the `cycles` set (81 messages on an AD × PT grid, plus plaintext-only 16 B and
64 B) with `LWC_TB` in timing mode. Each message's time runs from the first input word accepted to the final
status word. Outputs are still checked, so wrong RTL fails instead of giving numbers.

**Profile (`make profile WL=short|long`).** One encryption (new key) plus one decryption (same key) of 16+16 B
or 1536+1536 B. Questa dumps the core's handshakes and the busy probes listed in `rtl/<core>/profile.txt` (one
`std_logic` per permutation unit or stage, '1' while it computes), and `scripts/profile.py` classifies every cycle.

**Fmax and area (`make synth`).**
- **Fixed flow:** out-of-context synthesis, opt, place, phys_opt, route on `xc7a100tftg256-2L`. No I/O
  constraints, so only paths inside the design are timed.
- **Fmax search (`scripts/fmax.py`):** a met run at target period P supports any period ≥ P − WNS, so
  Fmax = 1000 / (P − WNS). The first target is 8% tighter than a delay predicted from the rounds per stage and the calls in flight (Vivado
  works hardest under a tight target). After a failure it retargets at the achieved delay + 5% (then 10%,
  15%); after a met run it stops if a tighter failed run brackets it. At most 4 runs; the best met run wins.
  `PERIOD0=<ns>` overrides the first target.
- **Noise:** about ±0.3 ns run to run. Ignore Fmax differences under ~5%. If a result looks out of line, check
  the run history in `synth_runs.csv` and re-run from the met period.
- **Files:** `build/synth/<core>/p<period>/` holds each run's logs and `timing.rpt`, plus `paths.tsv` (worst path
  to each of up to 1000 endpoints).

**Critical path (`python3 scripts/critpath.py --core <core>`).** Classifies the worst paths of a core's latest
synthesis and lists the 3 worst *distinct* categories, with how much the period could shrink before each next
one becomes critical. Categories are in [sweep/README.md](sweep/README.md).

## profile.csv
| Column | Meaning |
|---|---|
| `window_cycles` | Cycles from the first activity to the last |
| `busy_io_pct` | A unit is busy **and** a word moves: the overlap optimizations want |
| `busy_pct` | A unit is busy, no I/O |
| `io_pct` | I/O while every unit is idle |
| `neither_pct` | No unit busy, no I/O: control or waiting |
| `any_busy_pct` | `busy_io_pct + busy_pct` |
| `unit_busy` | Busy cycles per probe (should equal permutations × cycles per permutation) |
| `units_concurrent` | Share of cycles with 0, 1, 2, … units busy |
| `in_words`, `out_words` | 32-bit words in and out; depends only on the workload, so must match across cores |

The four `_pct` categories sum to 100%. Baseline, long workload: 0% overlap, 56% compute, 44% with the
permutation idle. That idle 44% is what the optimizations go after.

## synth_results.csv and synth_runs.csv
| Column | Meaning |
|---|---|
| `rounds`, `cycles_per_perm` | Read from the core's RTL |
| `closed` | 1 if some run met timing; 0 means Fmax is an estimate |
| `best_period_ns`, `wns_ns`, `fmax_mhz` | Fastest met target, its slack, and `1000 / (period − WNS)` |
| `luts`, `ffs`, `slices` | Area |
| `bram_tiles`, `dsps` | Should be 0; nonzero means Vivado inferred something unexpected |
| `runs` | Vivado runs the search took |
| `part`, `vivado` | Results are only comparable on the same part and tool version |

`synth_runs.csv` has one row per run instead, with `iter`, the target `period_ns`, `met`, `fmax_est_mhz` and
`runtime_s`.

## Target part
All results use **`xc7a100tftg256-2L`** (set by `PART` in `scripts/synth.py`): the CW305 board's FPGA and the
part GMU used for ePrint 2023/484, so our numbers compare directly with `Elephant_GMU` (222 MHz, 1375 LUT,
151 Kbps/LUT).
- Synthesis is out of context, so only the speed grade matters: the same chip gives the same LUT/FF counts in
  any package, but Fmax changes with the grade. A Nexys/Arty A7-100T (`xc7a100tcsg324-1`) would be slower and
  not comparable to the paper.
- Never compare Fmax or throughput across parts; `make report` flags `other_part`. Changing `PART` means
  re-synthesizing every core.
- Some older rows in `synth_results.csv` used other parts; check the `part` column.
