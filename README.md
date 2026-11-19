# Elephant Dumbo (v2) on FPGA

ECE545 final project: implement, optimize, verify and benchmark Elephant **Dumbo v2**
(Spongent-π[160]) on a Xilinx FPGA, compared against GMU's Elephant **v1** RTL.

**Naming:** `v1` / `v2` always means the *algorithm spec* (Elephant v1 vs the v2 finalist).
GMU's hardware variants (their `src_rtl/v1..v4`) are all spec v1; we call them arch1–arch4.
All GMU RTL implements Elephant **v1**, so the v2 core is our own port of GMU's arch-1 core.

## Status (2026-11-18)
| Item | State |
|---|---|
| v2 C model vs official KAT | 1089/1089 (encrypt, decrypt round-trip, forged tag rejected) |
| `core_v1` (GMU arch-1, unmodified), Questa 2026.1 | passes every v1 set: gmu 3201, random 1000, edge 374, full33 2178, long 10, badtag 374 |
| `core_v2` (our v1→v2 port), Questa 2026.1 | passes every v2 set: random 1000, edge 374, full33 2178, long 10, badtag 374 |
| GHDL | commands written, **never run** (not installed on the NCSU machine) |
| Synthesis (Vivado 2026.1) | `make synth` works; first sweep of core_v2 done at ROUNDS 1 and 4 (see Benchmarking). core_v1 not yet synthesized |

Not done yet:
- Spongent permutation unit testbench (`tb/unit/`) and the C trace tool (per-permutation state dumps).
- `collect_results.py` / `make bench`, optimization of the permutation.
- Mutation test (deliberately breaking the RTL to confirm the vectors catch it).
- `PERM_ROUNDS_PER_CYCLE` in `rtl/` is the upstream value (10, i.e. 8 cycles per permutation) in both
  cores. Only 1, 4, 5, 8, 10 and 16 are supported (see Benchmarking).

## Quick start
```sh
source ./setup.sh                   # NCSU machines: loads Questa (`source ./setup.sh vivado` adds Vivado)
make fetch                          # clone pinned upstream sources into ref/ (needed for cryptotvgen)
make models                         # venv + cryptotvgen, build C models, check v2 against the official KAT
make kat SPEC=v1                    # generate vectors into kat/v1/gen/
make kat SPEC=v2                    # generate vectors into kat/v2/gen/
make sim SPEC=v2 SET=edge           # run the testbench on core_v2 (about 25 s)
make sim-all SPEC=v2                # every vector set for v2 (about 4 min)
make sim SPEC=v1 SET=gmu            # core_v1 with GMU's own shipped vectors
make sim SPEC=v2 ROUNDS=4 SET=edge  # same, with 4 permutation rounds per cycle (copy of the RTL; rtl/ untouched)
make sim SIM=ghdl SPEC=v2 SET=edge  # GHDL instead of Questa
make synth SPEC=v2 SWEEP="1 4"       # Vivado Fmax/area for those ROUNDS (needs `source ./setup.sh vivado`)
make cycles SPEC=v2 ROUNDS=4         # cycles from LWC_TB's timing mode, checked against the cycle model
make help                           # target list and what each SET is for
```
`SPEC` (`v1` or `v2`) picks the C model, the core and the vectors; everything else is shared.
`models` and `kat` are one-time per checkout (their outputs are gitignored and reproducible);
after that, day-to-day work is just `make sim`.

## Layout
| Path | Purpose |
|---|---|
| `setup.sh` | Source it to load Questa (and optionally Vivado) via `module` |
| `ref/` | Upstream clones from `make fetch` (gitignored; read-only, for diffs) |
| `model/` | C reference models for v1 and v2, SUPERCOP layout (see `model/UPSTREAM.md`); `model/lib/` is built output |
| `rtl/lwc/` | GMU LWC wrapper, shared and frozen |
| `rtl/core_v1/` | GMU arch-1 core, unmodified: the known-good v1 hardware |
| `rtl/core_v2/` | Dumbo v2 core, ported from core_v1 (see `rtl/core_v2/V2_PORT.md`) |
| `tb/` | `LWC_TB` (GMU's testbench, shared by both specs); `tb/unit/` reserved for the permutation testbench |
| `kat/` | Test vectors (see `kat/README.md`) |
| `scripts/` | `fetch_sources.sh`, `gen_kat.py`, `check_model_kat.py`, `sim_result.sh`; benchmarking: `prep_rtl.py`, `vivado_build.tcl`, `synth_sweep.py` |
| `reports/` | `synth_results.csv` (one row per design point), `synth_runs.csv` (every Vivado run), `perf_model.csv` (design point x workload: modelled cycles, latency, throughput) |
| `docs/` | AI usage log (required by the course), spec PDFs for Elephant v1/v2 and the NIST final-round report |

Provenance of copied files (source repo and commit) is in `rtl/UPSTREAM.md`, `tb/UPSTREAM.md`
and `model/UPSTREAM.md`.

## How validation works
```
make models   C ref --compile--> model/lib/*.so --check--> official v2 KAT (1089 vectors)
make kat      model/lib/*.so --cryptotvgen--> kat/<spec>/gen/<set>/{pdi,sdi,do}.txt
make sim      LWC_TB drives pdi/sdi into the RTL and compares each output word to do.txt
              --> result.txt --> sim_result.sh --> PASS / FAIL banner
```
1. **`make models`**: builds the C references into shared libraries and checks the v2 one against
   the official KAT (`scripts/check_model_kat.py`). If this fails, nothing downstream is trustworthy.
2. **`make kat SPEC=…`**: `scripts/gen_kat.py` has cryptotvgen call the C model to produce
   `pdi.txt` (public inputs), `sdi.txt` (keys) and `do.txt` (expected outputs, computed by the C
   model). Fixed seed, so it is reproducible. `badtag` is derived from `edge` by flipping tag bits.
3. **`make sim SPEC=… SET=…`**: compiles `rtl/core_<spec>/filelist.txt` + `tb/filelist.txt` and runs
   `LWC_TB`. Questa is the default simulator. The comparison happens *inside* the simulation:
   - `LWC_TB` reads `pdi.txt`/`sdi.txt` and drives them into the design over the LWC interface.
   - Each 32-bit word the design outputs is compared to the next word of `do.txt`.
   - On a mismatch it logs MsgID, line, word, expected and received values to
     `failed_test_vectors.txt` and stops (`G_MAX_FAILURES = 0`).
   - At the end it writes `result.txt` (`0` = pass, `1` = fail); `scripts/sim_result.sh` reads it and
     prints a PASS / FAIL / ERROR banner, with the number of vectors verified.
   - The design's raw output is not saved, so there is no output file to diff by hand.

Output goes to `build/sim/<sim>/<spec>/<set>/`: `log.txt`, `failed_test_vectors.txt`, `result.txt`,
`sim.out` (full simulator transcript), `timing.csv` (empty, see Status).

**`SPEC=v1` is the control:** GMU's core must always pass. If `core_v2` fails and v1 passes, the bug is
in `core_v2`, not the models, vectors or testbench.


## The v2 port (summary)
Details in `rtl/core_v2/V2_PORT.md`; `diff -r rtl/core_v1 rtl/core_v2` shows every change.
Only `elephant_datapath.vhd` and `CryptoCore.vhd` differ. The permutation, mask LFSR, wrapper and
testbench are unchanged.
- **Masks:** the existing LFSR window (prev, cur, next) is enough. AD blocks ≥ 1 use `prev`; the
  keystream uses `prev ⊕ cur`; the ciphertext MAC uses `prev ⊕ next`. The mask select grew to 3 bits.
- **First AD block (N‖AD₀):** no longer permuted; it initializes the tag.
- **Tag:** the accumulator is 160 bits (was 64).
- **Final step:** after the last ciphertext MAC, T = trunc64(P(S ⊕ L) ⊕ L), one extra permutation.
  L = P(K‖0) is already stored in `key_out`.

## Where to edit
| To change… | Edit |
|---|---|
| The v2 hardware | `rtl/core_v2/*.vhd` (add new files to `rtl/core_v2/filelist.txt`, in compile order) |
| Vector lengths / sets / seed | `AD_LENS`, `PT_LENS`, `LONG`, `--seed`, `--sets` in `scripts/gen_kat.py` (`SETS` in the `Makefile` for `sim-all`) |
| cryptotvgen parameters (sizes, I/O width) | `COMMON` in `scripts/gen_kat.py`; must match the algorithm's `api.h` |
| Testbench or wrapper | Avoid. `tb/` and `rtl/lwc/` are upstream and shared by both specs; change only with a reason and note it in the `UPSTREAM.md` |
| Simulator flags | the `SIM` default, `GHDLFLAGS` and the `questa` branch in the `Makefile` |
| PASS/FAIL banner | `scripts/sim_result.sh` (`NO_COLOR=1` disables color) |

Dev loop: edit `core_v2` → `make sim SPEC=v2 SET=edge` → `make sim-all SPEC=v2` →
`make sim-all SPEC=v1` (regression). On a failure, read
`build/sim/<sim>/<spec>/<set>/failed_test_vectors.txt`.

## Benchmarking (Fmax and area)
`make synth SPEC=v2 SWEEP="1 4"` runs Vivado (needs `source ./setup.sh vivado`) on the LWC top, wrapper plus
core, for each `PERM_ROUNDS_PER_CYCLE` value in `SWEEP`:
- **Part and flow (fixed for every point):** `xc7a12tcpg238-3` (Artix-7 12T, set at the top of
  `scripts/synth_sweep.py`); out-of-context synth, then opt, place, phys_opt, route. No I/O constraints, so
  only paths inside the design are timed.
- **Fmax search:** Vivado reports slack, not a maximum frequency, so the script retargets the clock from the
  achieved slack (`period - WNS`) until timing is met within 3% of the target (default start 6 ns, up to 5
  runs). Fmax = 1000 / (period - WNS) from the fastest run that met timing. A line is printed when each
  iteration starts and finishes; the full log of each run is in `build/synth/<spec>_r<N>/p<period>/`.
- **Rounds per cycle:** `ROUNDS` / `SWEEP` values are applied to a copy of the RTL under `build/rtl/`
  (`scripts/prep_rtl.py`); `rtl/` is never edited. Supported values are **1, 4, 5, 8, 10, 16**:
  `elephant_perm.vhd` only has round-constant tables for these, and other values that divide 80 (e.g. 2)
  silently give wrong results, so `prep_rtl.py` rejects them.
- **Verify before you synthesize:** `make sim-all SPEC=v2 ROUNDS=<n>` must pass first, so the numbers are for a
  design that works.
- **Results:** `reports/synth_results.csv` (one row per design point: Fmax, LUT, FF, slices, BRAM, DSP) and
  `reports/synth_runs.csv` (every Vivado run).

### First results (core_v2, xc7a12tcpg238-3, Vivado 2026.1, out-of-context)
Both configurations pass every v2 vector set in simulation (random, edge, full33, long, badtag).

| ROUNDS | cycles/perm | Target met | Fmax est. | LUT | FF | Slices | BRAM/DSP | Vivado runs |
|---|---|---|---|---|---|---|---|---|
| 1 | 80 | 5.674 ns (176 MHz) | 179.9 MHz | 1546 | 1089 | 508 | 0 / 0 | 5 |
| 4 | 20 | 6.000 ns (167 MHz) | 170.0 MHz | 1802 | 1080 | 544 | 0 / 0 | 1 |

- **Fmax est.** is `1000 / (period - WNS)` from the passing run, i.e. what that run's achieved delay implies.
  The clock actually *met* in a run is the "Target met" column; use that for conservative claims.
- **Run-to-run noise is about ±0.3 ns.** For ROUNDS=1, a 5.813 ns target met with +0.242 ns slack but a tighter
  5.583 ns target failed by 0.321 ns. Treat differences under ~5% between design points as noise until
  several placements per point are compared. ROUNDS=4 converged after a single run, so it is the less
  well-explored of the two.
- **What limits the clock** (worst path in each report):
  - ROUNDS=1: `CryptoCore data_cnt_int` -> `PostProcessor` FSM state (10 logic levels), a controller/wrapper
    path, not the permutation.
  - ROUNDS=4: `perm_cnt_int` -> `ms_reg_out` (round-constant lookup, 5 logic levels, 79% of the delay is routing).
  So unrolling more rounds will not help until these two paths are shortened.
- Throughput numbers for these points are in `reports/perf_model.csv` (see Cycle model below).

## Cycle model (core_v2)
`scripts/cycle_model.py` predicts the testbench's execution time (first input word accepted to final
status word) for any AD/message length. `make cycles` measures it (`LWC_TB` with `G_TEST_MODE=4`, the
`cycles` vector set, 75 vectors) and `python3 scripts/cycle_model.py --validate` compares: **450 measurements
over ROUNDS 1, 4, 5, 8, 10, 16, max error 0 cycles.**

```
PC     = 80 / ROUNDS                                  cycles per permutation
nAD    = floor((12 + AD) / 20)                        AD blocks that are permuted (block 0 is not)
nK     = max(ceil(M / 20), 1)                         keystream permutations
nC     = floor(M / 20) + 1                            ciphertext-MAC permutations
cycles = (nAD + nK + nC + 1 + new_key) * PC + 18 + 8*nAD + 3*nK + 8*nC + 4*new_key
```
- The core runs **one permutation at a time and never overlaps I/O with it**. Each full message block costs
  two permutations (keystream + MAC) plus 11 non-permutation cycles, i.e. `2*PC + 11`. The spec allows these
  to run in parallel; the RTL does not use that.
- **An empty message still runs a keystream permutation** (`nK = max(.., 1)`), one more than the spec needs.
  It costs `PC + 3` cycles whenever the message is empty (see `perms_spec` vs `perms_hw` in the CSV).
- Decrypt costs exactly what encrypt costs. A new key adds one permutation and 4 cycles.
- Permutation share of the time (`perm_share` in the CSV): about 90% at ROUNDS=1 and 68-78% at ROUNDS=4,
  so unrolling alone saturates; the 8 non-permutation cycles per block matter next.
- Coefficients (8, 3, 8, 4, 18) were fitted to simulation, not derived by hand from every FSM state, so
  re-run `make cycles` after any change to `CryptoCore.vhd`: `--validate` fails if the model no longer matches.

`make synth` appends, for each design point, one row per workload to `reports/perf_model.csv`: modelled
cycles with the Fmax and LUT count Vivado just measured, giving latency, throughput (Mbps, AD + message
bytes) and Mbps per kLUT. `python3 scripts/cycle_model.py --from-results` rebuilds the CSV from
`synth_results.csv` without running Vivado. Workloads: 16 B AD + 16 B message (with and without a new key),
64+64 B, 1536 B message only, 1536 B AD only, 1536+1536 B. Throughput uses the model's cycle count at the
synthesized Fmax, so it inherits the Fmax caveats above (the ±0.3 ns run-to-run noise).

## Gotchas
- **cryptotvgen** needs the `requests` module but does not declare it (`make models` installs it).
  Without `--candidates_dir` it silently downloads all of SUPERCOP (~50 MB into `~/.cryptotvgen/`);
  `gen_kat.py` always passes it.
- **`LWC_TB` result file** is exit-code style: `0` = pass, `1` = fail.
- **Default `SET`** is `edge` (see the `Makefile`).
- **AD block boundaries** sit at 8, 28, 48 B (the first block holds the 12-byte nonce); PT/CT
  boundaries at 20, 40, 60 B.
- **Generated vectors are gitignored** (`kat/*/gen/*/`); only `kat/v1/gmu/` is tracked.

## Toolchain
Questa 2026.1 or GHDL (simulation), Vivado batch mode (synthesis; target xc7a12t), Python 3 venv with
cryptotvgen 1.2.0, gcc. Not yet a git repository.
