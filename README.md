# Elephant Dumbo v2 on FPGA

ECE545 final project: implement, verify, optimize and benchmark Elephant **Dumbo v2** (Spongent-π[160]) on a
Xilinx Artix-7 (`xc7a100tftg256-2L`, the part GMU used to benchmark the NIST LWC finalists).

- **Baseline:** `brody/base_r10`, our port of GMU's arch-1 Elephant core from spec v1 to v2, at GMU's default
  of 10 rounds per cycle ([what the port changed](rtl/brody/base_r10/README.md)). Every speedup is measured
  against it.
- **Background:** [DUMBO_V2.md](DUMBO_V2.md) explains the algorithm and where its cycles go.
- **Every core and its numbers:** [rtl/README.md](rtl/README.md). **How each speedup works:** [rtl/ACCELERATION.md](rtl/ACCELERATION.md).
- **Graphs:** [reports/graphs/README.md](reports/graphs/README.md). **CSV columns:** [reports/README.md](reports/README.md).

`v1` / `v2` always means the *algorithm spec*. All of GMU's RTL is spec v1, so every v2 core here starts from
our own port.

## Results

Long-message plaintext throughput on xc7a100tftg256-2L, Vivado 2026.1, LWC wrapper included
(source: `reports/benchmark.csv`).

| Core | What it is | Fmax (MHz) | LUT | Mbps | Kbps/LUT | × base_r10 |
|---|---|---|---|---|---|---|
| Elephant_GMU (ePrint 2023/484) | GMU's published core, 1 round/cycle | 222 | 1375 | 208 | 151 | 0.39 |
| `brody/base_r10` | **baseline**: our v2 port | 90.5 | 2918 | 539 | 185 | 1.00 |
| `brody/r4_BtoJ` | end of our r4 path (options B–J) | 182.4 | 5396 | 5906 | 1094 | 10.95 |
| `brody/r2_BtoL` | end of our r2 path (B–L), our best own core | 208.0 | 5742 | 6734 | 1173 | 12.48 |
| `merged/ring40_IL` | Logan's ring + our I, L: **fastest** | 249.2 | 5700 | 8021 | 1407 | 14.87 |
| `merged/ring32_ILN` | 32-round ring with two entry points: **best Kbps/LUT** | 247.1 | 5176 | 8000 | 1546 | 14.83 |

Both merged cores beat every unprotected design in GMU's benchmark on long-message plaintext throughput
(the fastest there is Ascon-128a at 5421 Mbps).

## Verification status

| Check | Result |
|---|---|
| v2 C model vs official KAT | 1089/1089 (encrypt, decrypt round-trip, forged tag rejected) |
| `gmu/arch1_v1` (control, spec v1), Questa | passes gmu 3201, random 1000, edge 374, full33 2178, long 10, badtag 374 |
| Every optimized v2 core in `rtl/README.md`, Questa | passes random 1000, edge 374, full33 2178, long 10, badtag 374; `make cycles` checks 81 more |
| `brody/base_rN` reference variants | pass edge, long, badtag and cycles |
| GHDL | commands written, **never run** (not installed on the NCSU machines) |

Not done: a unit testbench for the permutation (`tb/unit/`), per-permutation C traces, and a mutation test.

## Quick start
```sh
source ./setup.sh                      # NCSU: load Questa (`source ./setup.sh vivado` adds Vivado)
scripts/fetch_sources.sh               # clone pinned upstream sources into ref/
make models                            # venv + cryptotvgen, build C models, check v2 against the official KAT
make kat SPEC=v1 && make kat SPEC=v2   # generate test vectors into kat/<spec>/gen/
make sim CORE=brody/base_r10 SET=edge  # one vector set (about 25 s)
make sim-all CORE=brody/base_r10       # every validation set (about 4 min)
make help                              # all targets and sets
```
`CORE` is the core's path under `rtl/`. The spec (which C model and vectors) is v1 for `gmu/*` and v2 for
everything else. `models` and `kat` are one-time per checkout; after that it's just `make sim`.

## Layout
| Path | Contents |
|---|---|
| `rtl/` | Every core, named by author and options (rules and index in `rtl/README.md`); `rtl/shared/lwc/` is GMU's LWC wrapper (frozen) |
| `tb/` | GMU's `LWC_TB` testbench, shared by both specs |
| `kat/` | Test vectors ([kat/README.md](kat/README.md)) |
| `model/` | C reference models for v1 and v2 (SUPERCOP layout) |
| `scripts/` | Vector generation, simulation result check, profiling, synthesis + Fmax search, report, graphs, sweep |
| `reports/` | Benchmark CSVs, graphs, and the design-space sweep |
| `docs/` | Specs, the NIST final-round report, GMU's benchmark paper, and the AI usage log (course requirement) |
| `ref/` | Upstream clones from `scripts/fetch_sources.sh` (gitignored, read-only) |

Provenance of copied files is in `rtl/UPSTREAM.md`, `tb/UPSTREAM.md` and `model/UPSTREAM.md`.
Old core names (`core_v2_r4_optBCD`, `pipe20x2d16_IL`, …) map to current ones in `rtl/RENAMES.csv`.

## How validation works
```
make models   C ref --> model/lib/*.so --check--> official v2 KAT (1089 vectors)
make kat      model/lib/*.so --cryptotvgen--> kat/<spec>/gen/<set>/{pdi,sdi,do}.txt
make sim      LWC_TB drives pdi/sdi into the RTL, compares every output word to do.txt --> PASS / FAIL
```
1. **`make models`** builds the C references and checks v2 against the official KAT. If this fails, nothing
   downstream can be trusted.
2. **`make kat`** has cryptotvgen call the C model to write public inputs (`pdi.txt`), keys (`sdi.txt`) and
   expected outputs (`do.txt`). The seed is fixed, so the vectors are reproducible.
3. **`make sim`** runs `LWC_TB` (Questa by default). It compares each 32-bit output word to `do.txt`, stops at the
   first mismatch, and `scripts/sim_result.sh` prints a PASS / FAIL banner with the vector count.

Output is in `build/sim/<sim>/<core>/<set>/`. On a failure, read `failed_test_vectors.txt` there (MsgID, line,
expected and received word).

**`gmu/arch1_v1` is the control.** GMU's unmodified core must always pass. If a v2 core fails and the control
passes, the bug is in the v2 core, not in the models, vectors or testbench.

## Working on a core
Dev loop: edit `rtl/<core>/` → `make sim CORE=<core> SET=edge` → `make sim-all CORE=<core>`.
If anything shared changed (testbench, wrapper, vectors), re-run `sim-all` on `brody/base_r10` and `gmu/arch1_v1` too.

**New core:** copy the closest existing core (`cp -r rtl/brody/r4_BtoJ rtl/brody/<name>`), fix the paths in
its `filelist.txt` (compile order), and keep the top entity name `CryptoCore`. Name it by the rules in
`rtl/README.md`. To isolate one option, start from the `brody/base_rN` with the same rounds per cycle and
compare against that.

**SystemVerilog cores** (`rtl/logan/`, `rtl/merged/ring*`): `.sv` files in `filelist.txt` are compiled with
`vlog -sv` after the VHDL (Questa only), and sizes come from the core's `defines.txt`.

| Don't edit | Why |
|---|---|
| `rtl/brody/base_r10/` | It is the baseline every speedup is measured against |
| `rtl/gmu/arch1_v1/`, `rtl/shared/lwc/`, `tb/` | Upstream and shared by every core; if you must, note why in the `UPSTREAM.md` |

Vector sets, lengths and the seed are set in `scripts/gen_kat.py` (`SETS` in the `Makefile` for `sim-all`).

## Benchmarking
Every core is measured with the same vectors, part and flow. Run the steps in order; step 1 must pass.

| Step | Command | Output |
|---|---|---|
| 1. Validate | `make sim-all CORE=<core>` | PASS on every set |
| 2. Cycles | `make cycles CORE=<core>` | `build/sim/questa/<core>/cycles/timing.csv` (81 messages, outputs checked) |
| 3. Profile | `make profile CORE=<core> WL=long` (and `WL=short`) | `reports/profile.csv`: where the cycles go |
| 4. Fmax, area | `make synth CORE=<core>` (needs `source ./setup.sh vivado`) | `reports/synth_results.csv` |
| 5. Compare | `make report` | `reports/benchmark.csv` |
| 6. Graphs | `make plots` | `reports/graphs/*.png` |

How each step measures, what every column means, and the Fmax search are in
[reports/README.md](reports/README.md). Two things to know up front:
- **Fmax noise is about ±0.3 ns run to run.** Treat Fmax differences under ~5% between cores as noise.
- **`checks` in `benchmark.csv` flags numbers not to trust** (stale RTL, failed cycles run, timing not closed).

## Gotchas
- **cryptotvgen** needs `requests` but doesn't declare it (`make models` installs it). Without
  `--candidates_dir` it silently downloads all of SUPERCOP; `gen_kat.py` always passes it.
- **cryptotvgen `--gen_custom` flags must be `1`/`0`.** It reads the string `False` as true, so before
  2026-11-19 "same key" vectors mostly loaded a new key.
- **Random-stall mode (`TESTMODE=1`) never finishes**, even on GMU's unmodified core, so backpressure is not
  validated. All validation uses mode 0 (no stalls).
- **`PERM_ROUNDS_PER_CYCLE`** in the `base_rN` cores only works for 1, 4, 5, 8, 10 and 16: GMU's
  `elephant_perm.vhd` has round-constant tables only for these. Other divisors of 80 compile but give wrong
  results. (`brody/r4_BtoG` onward and `brody/gen` compute the constants for any value.)
- **Block boundaries:** AD blocks end at 8, 28, 48 B (the first block holds the 12-byte nonce); PT/CT blocks at
  20, 40, 60 B.
- **`LWC_TB`'s result file** is exit-code style: `0` = pass.

## Toolchain
Questa 2026.1 (or GHDL, untested), Vivado 2026.1 in batch mode, Python 3 venv with cryptotvgen 1.2.0, gcc.
