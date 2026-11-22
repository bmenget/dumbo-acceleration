# Elephant Dumbo (v2) on FPGA

ECE545 final project: implement, optimize, verify and benchmark Elephant **Dumbo v2**
(Spongent-π[160]) on a Xilinx FPGA. The baseline is our unmodified v2 port (`core_v2`).

**Naming:** `v1` / `v2` always means the *algorithm spec* (Elephant v1 vs the v2 finalist).
GMU's hardware variants (their `src_rtl/v1..v4`) are all spec v1; we call them arch1–arch4.
All GMU RTL implements Elephant **v1**, so the v2 core is our own port of GMU's arch-1 core.

## Status (2026-11-19)
| Item | State |
|---|---|
| v2 C model vs official KAT | 1089/1089 (encrypt, decrypt round-trip, forged tag rejected) |
| `core_v1` (GMU arch-1, unmodified), Questa 2026.1 | passes every v1 set: gmu 3201, random 1000, edge 374, full33 2178, long 10, badtag 374 |
| `core_v2` (our v1→v2 port), Questa 2026.1 | passes every v2 set: random 1000, edge 374, full33 2178, long 10, badtag 374 |
| GHDL | commands written, **never run** (not installed on the NCSU machine) |
| Baseline benchmark, xc7a100tftg256-2L | `core_v2`: 90.5 MHz, 2918 LUT, 1079 FF; plaintext 539 Mbps long, 219 Mbps at 16 B; 184.8 Kbps/LUT. See `reports/benchmark.csv` |
| Rounds-per-cycle sweep | `core_v2_r1/r4/r5/r8/r16` (`core_v2` with only `PERM_ROUNDS_PER_CYCLE` changed), all benchmarked |
| `core_v2_r4_optB` (option B: I/O overlapped with the permutation, on `core_v2_r4`) | passes every v2 set. vs `core_v2_r4`: 50.74 → 42.81 cycles per PT block, 28.08 → 22.06 per AD block; 184.3 MHz, 1882 LUT, 1243 FF; 689 Mbps long PT, 366 Kbps/LUT. See `rtl/core_v2_r4_optB/OPT_B.md` |
| `core_v2_r4_optBC` (options B + C: I/O overlap and two permutation units) | passes every v2 set. 21.74 cycles per PT block, 11.19 per AD block; 169.5 MHz, 2736 LUT, 1572 FF; 1247 Mbps long PT (×2.31 vs `core_v2`), 456 Kbps/LUT. See `rtl/core_v2_r4_optBC/OPT_BC.md` |
| `core_v2_r4_optBCD` (B + C + D: two units, each two 4-round pipeline stages, 4 calls in flight) | passes every v2 set. 10.87 cycles per PT block, 6.50 per AD block; 147.8 MHz, 4732 LUT, 2403 FF; 2175 Mbps long PT (×4.03 vs `core_v2`), 460 Kbps/LUT. See `rtl/core_v2_r4_optBCD/OPT_BCD.md` |

Not done yet:
- Spongent permutation unit testbench (`tb/unit/`) and the C trace tool (per-permutation state dumps).
- Mutation test (deliberately breaking the RTL to confirm the vectors catch it).

## Quick start
```sh
source ./setup.sh                   # NCSU machines: loads Questa (`source ./setup.sh vivado` adds Vivado)
make fetch                          # clone pinned upstream sources into ref/ (needed for cryptotvgen)
make models                         # venv + cryptotvgen, build C models, check v2 against the official KAT
make kat SPEC=v1                    # generate vectors into kat/v1/gen/
make kat SPEC=v2                    # generate vectors into kat/v2/gen/
make sim CORE=v2 SET=edge           # run the testbench on core_v2 (about 25 s)
make sim-all CORE=v2                # every validation set (about 4 min)
make sim CORE=v1 SET=gmu            # core_v1 with GMU's own shipped vectors
make sim SIM=ghdl CORE=v2 SET=edge  # GHDL instead of Questa
make help                           # target list and what each SET is for
```
`CORE` picks the RTL (`rtl/core_<CORE>/`); the part before the first `_` is the spec, which picks the
C model and vectors (`v2_opt1` is checked against v2). `SPEC=v1`/`SPEC=v2` still work as shorthand
for `CORE=v1`/`CORE=v2`.
`models` and `kat` are one-time per checkout (their outputs are gitignored and reproducible);
after that, day-to-day work is just `make sim`.

## Layout
| Path | Purpose |
|---|---|
| `DUMBO_V2.md` | How Dumbo v2 works: algorithm, computational profile, and how `core_v2` schedules it |
| `setup.sh` | Source it to load Questa (and optionally Vivado) via `module` |
| `ref/` | Upstream clones from `make fetch` (gitignored; read-only, for diffs) |
| `model/` | C reference models for v1 and v2, SUPERCOP layout (see `model/UPSTREAM.md`); `model/lib/` is built output |
| `rtl/lwc/` | GMU LWC wrapper, shared and frozen |
| `rtl/core_v1/` | GMU arch-1 core, unmodified: the known-good v1 hardware |
| `rtl/core_v2/` | Dumbo v2 core, ported from core_v1 (see `rtl/core_v2/V2_PORT.md`): **the benchmark baseline** |
| `rtl/ACCELERATION.md` | Speed-up options A–D (unroll, I/O overlap, two units, pipelining): which files each touches and how |
| `rtl/core_v2_r*/` | Reference only: `core_v2` at 1, 4, 5, 8 or 16 rounds per cycle (see each `REFERENCE.md`). `r1` compares with `Elephant_GMU` in ePrint 2023/484 |
| `rtl/core_v2_r4_optB/` | Option B on `core_v2_r4`: AD and message I/O overlapped with the permutation (see `OPT_B.md`) |
| `rtl/core_v2_r4_optBC/` | Options B + C: optB plus a second permutation unit (AD pairs, MAC(k) ‖ KS(k+2)); see `OPT_BC.md` |
| `rtl/core_v2_r4_optBCD/` | Options B + C + D: 4 permutation slots (2 units × 2 pipeline stages), batch loader, 7-mask LFSR; see `OPT_BCD.md` |
| `rtl/core_v2[_rN]_opt*/` | Further optimized v2 cores, one directory each (see Benchmarking) |
| `tb/` | `LWC_TB` (GMU's testbench, shared by both specs); `tb/unit/` reserved for the permutation testbench |
| `kat/` | Test vectors (see `kat/README.md`) |
| `rtl/core_v2_gen/` | Parameterized core (rounds per unit R, pipeline stages S, units U, fast loader) for the design-space sweep; see `GEN.md` |
| `scripts/` | `fetch_sources.sh`, `gen_kat.py`, `check_model_kat.py`, `sim_result.sh`; benchmarking: `profile.py`, `synth.py`, `vivado_build.tcl`, `report.py`, `metrics.py` (metric formulas shared by report and sweep), `critpath.py` (critical-path classifier); sweep: `sweep.py` |
| `reports/` | `benchmark.csv` (every core vs baseline), `profile.csv` (cycle breakdown), `synth_results.csv`, `synth_runs.csv`; `sweep/` (design-space sweep of `core_v2_gen`, see `reports/sweep/README.md`) |
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
3. **`make sim CORE=… SET=…`**: compiles `rtl/core_<core>/filelist.txt` + `tb/filelist.txt` and runs
   `LWC_TB`. Questa is the default simulator. The comparison happens *inside* the simulation:
   - `LWC_TB` reads `pdi.txt`/`sdi.txt` and drives them into the design over the LWC interface.
   - Each 32-bit word the design outputs is compared to the next word of `do.txt`.
   - On a mismatch it logs MsgID, line, word, expected and received values to
     `failed_test_vectors.txt` and stops (`G_MAX_FAILURES = 0`).
   - At the end it writes `result.txt` (`0` = pass, `1` = fail); `scripts/sim_result.sh` reads it and
     prints a PASS / FAIL / ERROR banner, with the number of vectors verified.
   - The design's raw output is not saved, so there is no output file to diff by hand.

Output goes to `build/sim/<sim>/<core>/<set>/`: `log.txt`, `failed_test_vectors.txt`, `result.txt`,
`sim.out` (full simulator transcript), `timing.csv` (filled only by `make cycles`).

**`CORE=v1` is the control:** GMU's core must always pass. If `core_v2` fails and v1 passes, the bug is
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
| The baseline v2 hardware | Don't: `rtl/core_v2/` is the baseline every speedup is measured against |
| An optimized core | `rtl/core_v2[_rN]_optN/*.vhd`; new files go in its `filelist.txt` (compile order), busy probes in its `profile.txt` |
| Vector lengths / sets / seed | `AD_LENS`, `PT_LENS`, `LONG`, `--seed`, `--sets` in `scripts/gen_kat.py` (`SETS` in the `Makefile` for `sim-all`) |
| cryptotvgen parameters (sizes, I/O width) | `COMMON` in `scripts/gen_kat.py`; must match the algorithm's `api.h` |
| Testbench or wrapper | Avoid. `tb/` and `rtl/lwc/` are upstream and shared by both specs; change only with a reason and note it in the `UPSTREAM.md` |
| Simulator flags | the `SIM` default, `GHDLFLAGS` and the `questa` branch in the `Makefile` |
| PASS/FAIL banner | `scripts/sim_result.sh` (`NO_COLOR=1` disables color) |

Dev loop: edit `core_v2_opt1` → `make sim CORE=v2_opt1 SET=edge` → `make sim-all CORE=v2_opt1`.
On a failure, read `build/sim/<sim>/<core>/<set>/failed_test_vectors.txt`. If something shared changed
(testbench, wrapper, vectors), re-run `make sim-all CORE=v2` and `make sim-all CORE=v1` too.

## Benchmarking
Every optimized core lives in its own directory and is measured against the baseline `core_v2` with the
same vectors, the same part and the same flow.

**Start a new core:** `cp -r rtl/core_v2 rtl/core_v2_opt1`, then fix the paths in
`rtl/core_v2_opt1/filelist.txt` (`core_v2` → `core_v2_opt1`) and edit the VHDL. Keep the entity name
`CryptoCore` (the wrapper instantiates it). If you add or rename permutation units, update `profile.txt`.
To isolate one optimization, copy the `core_v2_rN` with the same rounds per cycle instead, name the result
`core_v2_rN_<opt>` (e.g. `core_v2_r4_optB`), and compare it against that `core_v2_rN`.
`rtl/ACCELERATION.md` lists the options and the files each one touches.

| Step | Command | Output |
|---|---|---|
| 1. Validate | `make sim-all CORE=v2_opt1` | must PASS; every number below assumes it |
| 2. Cycles | `make cycles CORE=v2_opt1` | `build/sim/questa/<core>/cycles/timing.csv` |
| 3. Profile | `make profile CORE=v2_opt1 WL=long` (and `WL=short`) | `reports/profile.csv` |
| 4. Fmax, area | `make synth CORE=v2_opt1` (`source ./setup.sh vivado`) | `reports/synth_results.csv` |
| 5. Compare | `make report` | `reports/benchmark.csv` |

**Cycles (`make cycles`).** Runs the `cycles` vector set (81 vectors: an AD x PT grid plus plaintext-only 16 B and 64 B)
with `LWC_TB` in its timing mode (`G_TEST_MODE=4`). Each row of `timing.csv` is one message: sizes, new key
or not, and the execution time in cycles from the first input word accepted to the final status word. The
run checks every output too, so wrong RTL fails instead of giving numbers.

**Profile (`make profile`).** Answers "where do the cycles go?" for one workload: `WL=short` (16+16 B) or
`WL=long` (1536+1536 B), each an encrypt with a new key plus a decrypt with the same key. Questa dumps a VCD
of the core's data handshakes and its busy probes, and `scripts/profile.py` classifies every cycle:
- `busy+io`: a permutation unit is busy *and* a word moves in or out (the overlap an optimization wants)
- `busy`: a unit is busy, no I/O
- `io`: I/O only
- `neither`: control or waiting

It also reports how busy each unit is and how often several units are busy at once. Probes come from
`rtl/core_<core>/profile.txt` (`<label> <path below the CryptoCore instance>`, one per permutation unit,
each a `std_logic` that is '1' exactly when that unit computes rounds). Baseline, long workload: 55.7% busy,
0.0% busy+io, 23.2% io only, 21.2% neither. The baseline never overlaps I/O with the permutation.

**Fmax and area (`make synth`).**
- **Part and flow (fixed for every core):** `xc7a100tftg256-2L` (XC7A100T-2FTG256L: the CW305 board's FPGA
  and the part GMU used to benchmark the LWC finalists; set at the top of `scripts/synth.py`; alternatives in
  `reports/README.md`); out-of-context synth, then opt, place, phys_opt, route.
  No I/O constraints, so only paths inside the design are timed.
- **Fmax search (`scripts/fmax.py`, shared with the sweep):** Vivado reports slack, not a maximum frequency.
  A met run at target P supports any period >= P - WNS (the achieved delay), so Fmax = 1000 / (P - WNS).
  - **Probe:** the first target is a tight one, 8% below a delay predicted from the rounds per cycle and
    the calls in flight. Vivado optimizes hardest under a tight target and stops once a target is met.
  - **After a failure:** retarget at the achieved delay + 5% (then 10%, 15%).
  - **After a met run:** finish if a tighter failed run brackets it; otherwise tighten again.
  - **Result:** the best met run, at most 4 runs. `python3 scripts/fmax.py calibrate` re-derives the
    constants from `reports/synth_runs.csv`. On the first 29 runs, the old rule (retarget at the achieved
    delay) averaged 2.9 runs and left one core unclosed; the new one should take about 2.
  - **Files:** each run's logs and reports (including `timing.rpt`, with the critical path) are in
    `build/synth/<core>/p<period>/`.
- **Run-to-run noise is about ±0.3 ns.** Treat Fmax differences under ~5% between cores as noise.
- **Baseline critical path:** `perm_cnt_int` (round-constant select) through all 10 unrolled rounds into
  `ms_reg_out`: 11 logic levels, 85% of the delay is routing.

**Report (`make report`).** For every v2 core with a `cycles` run, joins its measured cycles with its most
recent synthesis and writes `reports/benchmark.csv`, one row per core. The columns follow GMU's LWC benchmark
tables (ePrint 2023/484, Tables 12 and 14): plaintext throughput for long messages and for 1536, 64 and 16 B
(Mbit/s), AD throughput, Kbit/s per LUT, Fmax, LUTs and FFs, plus speedups against `core_v2` and the raw cycle
counts. The `checks` column flags numbers you should not trust: `cycles_failed`, `cycles_stale` or
`synth_stale` (the RTL changed after the measurement), `no_synth`, `other_part` and `not_closed`. Every column is explained
in `reports/README.md`.

**Critical path (`python3 scripts/critpath.py --core <core>`).** Classifies the 5 worst paths of a core's
latest synthesis (`perm`, `ctrl->datapath`, `core->wrapper`, `wrapper`, `tag`, `lfsr`, …; see
`reports/sweep/README.md`) and lists the 3 worst *distinct* categories with their gaps. The categories come
from `paths.tsv`, which `vivado_build.tcl` writes next to `timing.rpt` with the worst path to each of up to
1000 endpoints. Runs made before 2026-11-19 21:00 have no `paths.tsv` and fall back to the 5 paths.

**Design-space sweep (`scripts/sweep.py`).** Runs the parameterized core `rtl/core_v2_gen/` over a grid of
R (rounds per unit), S (pipeline stages per unit), U (units) and the fast loader. Each point is generated,
validated (`edge` + `cycles`), synthesized and classified, then deleted; only the most recent point's
build (`build/sweep/last/`) and failed points (`build/sweep/failed/`) are kept. Results go to
`reports/sweep/sweep.csv` with the same metric columns as `benchmark.csv`. See `reports/sweep/README.md`.

## Gotchas
- **cryptotvgen** needs the `requests` module but does not declare it (`make models` installs it).
  Without `--candidates_dir` it silently downloads all of SUPERCOP (~50 MB into `~/.cryptotvgen/`);
  `gen_kat.py` always passes it.
- **`LWC_TB` result file** is exit-code style: `0` = pass, `1` = fail.
- **Default `SET`** is `edge` (see the `Makefile`).
- **AD block boundaries** sit at 8, 28, 48 B (the first block holds the 12-byte nonce); PT/CT
  boundaries at 20, 40, 60 B.
- **Generated vectors are gitignored** (`kat/*/gen/*/`); only `kat/v1/gmu/` is tracked.
- **cryptotvgen `--gen_custom` flags must be `1`/`0`.** It reads the string `False` as true for NEW_KEY, so
  `True,False,...` vectors silently loaded a new key for almost every message (fixed 2026-11-19).
- **Random-stall mode (`TESTMODE=1`) doesn't complete,** even on GMU's unmodified `core_v1` (edge set: no
  vectors done after 240 s, against 25 s normally). It also hangs on `core_v2_r4`. Until that is understood, it can't
  validate backpressure handling. All validation uses the default mode 0 (no stalls).
- **`PERM_ROUNDS_PER_CYCLE`** (in each core's `elephant_constants.vhd`, 10 in `core_v1`/`core_v2`): only 1, 4, 5,
  8, 10 and 16 work. `elephant_perm.vhd` has round-constant tables only for these; other divisors of 80
  (e.g. 2) compile but give wrong results.

## Toolchain
Questa 2026.1 or GHDL (simulation), Vivado batch mode (synthesis; target xc7a100tftg256-2L), Python 3 venv with
cryptotvgen 1.2.0, gcc.
