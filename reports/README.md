# Reports

What each CSV in this folder holds, column by column, and why we track it. Every row is keyed by `core`
(`rtl/core_<core>/`). `v2` is the baseline that every other core is compared against.
`v2_r1` is a reference point, not an optimization: `core_v2` at one round per cycle, the configuration of
`Elephant_GMU` in GMU's benchmark paper (see `rtl/core_v2_r1/REFERENCE.md`).
`v2_r4`, `v2_r5`, `v2_r8` and `v2_r16` are the same kind of reference: `core_v2` at other unroll factors.
A core named `v2_rN_<opt>` (e.g. `v2_r4_optB`) applies one optimization to `core_v2_rN`. Judge its gain against
that `v2_rN` row, not against `v2` (the `x_` columns are always relative to `v2`).

| File | Written by | One row per |
|---|---|---|
| `benchmark.csv` | `make report` (rebuilt each run) | core |
| `profile.csv` | `make profile` (replaces that core and workload's row) | core x workload |
| `synth_results.csv` | `make synth` (appended) | synthesis of a core |
| `synth_runs.csv` | `make synth` (appended) | single Vivado run |

## benchmark.csv: the headline comparison
Joins each core's measured cycles (`make cycles`) with its latest Fmax and area (`make synth`). Columns follow
GMU's LWC finalist benchmark (Mohajerani et al., ePrint 2023/484, Tables 12 and 14), so our cores line up with
`Elephant_GMU` there. Throughput is in **Mbit/s** and efficiency in **Kbit/s per LUT**, both as in the paper.
All messages are encryptions with a reused key.

| Column | Meaning | Why |
|---|---|---|
| `rounds`, `cycles_per_perm` | `PERM_ROUNDS_PER_CYCLE` from the core's `elephant_constants.vhd`, and 80 / rounds. Blank if the core has no single value. | Speedups are only comparable when you know whether the unroll factor changed |
| `fmax_mhz`, `luts`, `ffs` | From the core's latest synthesis | Clock rate and area (paper Table 14) |
| `thr_pt_long` | Long-message plaintext throughput: bits added between 160 B and 1536 B plaintext, over the cycles added | Steady-state speed with per-message overhead removed (the paper's "Long") |
| `thr_pt_1536`, `thr_pt_64`, `thr_pt_16` | Plaintext-only messages (0 B AD) of that size: `8 x bytes x Fmax / cycles` | Real throughput at each size (paper Table 12) |
| `pct_long_1536`, `pct_long_64`, `pct_long_16` | That size's throughput as % of long | How much per-message overhead costs short messages |
| `thr_ad_long`, `ad_pt_ratio` | Long-message AD-only throughput, and AD over plaintext | AD needs one permutation per block, plaintext two |
| `kbps_per_lut_pt`, `kbps_per_lut_ad` | Long throughput per LUT | Efficiency. Shows whether a speedup was just bought with area. |
| `x_thr_pt_long`, `x_thr_pt_16`, `x_kbps_per_lut_pt` | This core divided by `core_v2` (above 1 is better) | Speedup against the baseline, for long messages, short messages, and efficiency |
| `cyc_blk_pt`, `cyc_blk_ad` | Steady-state cycles per 20-byte block | Architecture speed, independent of Fmax |
| `cyc_pt_16`, `cyc_pt_64`, `cyc_pt_1536` | Measured cycles for those plaintext sizes | The raw numbers behind the throughput |
| `part`, `synth_date`, `cycles_date` | Where and when the numbers came from | Staleness checks |
| `checks` | `cycles_failed`, `cycles_stale`, `synth_stale`, `no_synth`, `other_part`, `not_closed` | Flags numbers you shouldn't trust or report yet |

## profile.csv: where the cycles go
Covers one encryption (new key) plus one decryption (same key), clock cycle by clock cycle.

| Column | Meaning | Why |
|---|---|---|
| `window_cycles` | Cycles from the first activity to the last | Total time being classified |
| `busy_io_pct` | A permutation unit is busy **and** a word moves | Overlap. Optimizations should raise it. |
| `busy_pct` | A unit is busy, no I/O | Pure compute |
| `io_pct` | I/O while no unit is busy | Permutation idle while waiting for data |
| `neither_pct` | No unit busy and no I/O | Control or wait overhead |
| `any_busy_pct` | `busy_io_pct + busy_pct` | Permutation utilization |
| `unit_busy` | Busy cycles per unit (labels from `profile.txt`) | Shows each unit's load. Should equal permutations x cycles per permutation. |
| `units_concurrent` | Share of cycles with 0, 1, 2... units busy | Shows whether multiple units actually run in parallel |
| `in_words`, `out_words` | 32-bit words in and out | Sanity check. Depends only on the workload, so it must match across cores. |

The four `_pct` categories sum to 100%. The baseline's long run is 0% overlap, 56% compute and 44% idle
permutation. That idle 44% is the target.

## synth_results.csv: one result per synthesis
The best run of each `make synth`. `make report` uses the latest row for each core.

| Column | Meaning | Why |
|---|---|---|
| `rounds`, `cycles_per_perm` | Rounds per clock and cycles per permutation, read from the core's RTL | Fmax and area depend strongly on the unroll factor |
| `closed` | 1 if some run met timing | 0 means Fmax is only an estimate |
| `best_period_ns`, `wns_ns` | Fastest clock target that met timing, and its slack | Raw timing result |
| `fmax_mhz` | `1000 / (period - WNS)` | Maximum clock. Noise is about ±0.3 ns, so ignore differences under about 5%. |
| `luts`, `ffs`, `slices` | Logic, registers, occupied slices | Area cost |
| `bram_tiles`, `dsps` | Block RAMs and DSPs used | Should stay 0. Nonzero means Vivado inferred something unexpected. |
| `runs` | Vivado runs the Fmax search took | Effort and confidence |
| `part`, `vivado` | FPGA part and tool version | Results are only comparable on the same part and version |

## synth_runs.csv: every Vivado run
Same columns as above, but one row per iteration of the Fmax search: `iter`, the target `period_ns`, `met`,
`fmax_est_mhz` and `runtime_s`. Use it to see how the search converged and to judge run-to-run noise. Reports
use `synth_results.csv` instead.

## FPGA options
Set by `PART` at the top of `scripts/synth.py`. All results use **`xc7a100tftg256-2L`**.

| Option | Vivado part | Pros | Cons |
|---|---|---|---|
| **CW305 / paper part (current)** | `xc7a100tftg256-2L` | Same device GMU used to benchmark the LWC finalists (ePrint 2023/484), so our numbers compare directly with `Elephant_GMU` (222 MHz, 1,375 LUTs, 151 Kbps/LUT). It's the XC7A100T. | -2L is a faster grade than most student boards |
| Nexys / Arty A7-100T | `xc7a100tcsg324-1` | Common student board. Same chip. | Slowest speed grade. Not comparable to the paper. |
| GMU Round 2 part | `xc7a12tcpg238-3` | GMU's earlier LWC benchmarks used a 12T | Tiny device, fastest grade. Neither our target nor the paper's. |

Notes:
- **Only the speed grade affects our numbers.** Synthesis is out-of-context (no I/O pins), so the package doesn't
  matter, and the same chip gives the same LUT and FF counts. Fmax changes with the grade.
- **Never compare Fmax or throughput across parts.** `make report` flags `other_part` when a core's latest synthesis
  was on a different part.
- **Changing `PART` means re-synthesizing every core**, including the baseline. Cycle counts don't depend on the
  part.
- -2L is Xilinx's low-power bin of the -2 speed grade, with an extended (E) temperature range.
- Older rows in `synth_results.csv` used other parts; check the `part` column.
