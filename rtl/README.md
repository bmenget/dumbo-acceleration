# RTL: how cores are named, and every core at a glance

A core's name is its path under `rtl/`, and that name is used everywhere: `make sim CORE=brody/r4_BtoJ`, the
build folders (`build/synth/brody/r4_BtoJ/`), the `core` column of `reports/*.csv`, and the graphs.
Old names (`core_v2_r4_optBCDEFGHIJ`, `v2_logan_pipe20x2d16_optIL`, …) are mapped to new ones in
[RENAMES.csv](RENAMES.csv), for reading older notes and `docs/ai_usage_log.md`.

## Folders
| Folder | Contents |
|---|---|
| `shared/lwc/` | GMU's LWC wrapper, used by every core. Frozen. |
| `gmu/` | GMU's own core, unmodified. Spec v1; every other core is spec v2. |
| `brody/` | Brody's cores: the v2 port, its rounds-per-cycle variants, and the optimization path. |
| `logan/` | Logan's cores: `src/` holds his SystemVerilog, byte-identical (see [src/UPSTREAM.md](logan/src/UPSTREAM.md)); `glue/` our `design_pkg.vhd` for it; each other folder is one configuration (`defines.txt`). |
| `merged/` | Cores that combine both designs: Logan's rings with our options, or our cores with his ideas. |
| `attic/` | Superseded cores, still buildable. The author folder is kept (`attic/brody/…`). |

## Name rules
- **`base_rN`**: our v2 port of `gmu/arch1_v1` at N rounds per cycle (`PERM_ROUNDS_PER_CYCLE`); the `base_rN` cores
  differ only in that constant. **`base_r10`** keeps GMU's shipped default of 10 and is the baseline of every speedup;
  **`base_r1`** matches the published Elephant_GMU (1 round per cycle). `base_r10` was called `base` until 2026-11-23.
- **`rN_<first>to<last>`**: an optimized core with options *first* through *last* of
  [ACCELERATION.md](ACCELERATION.md) at N rounds per pipeline stage. The options were added in order, each core
  on top of the previous one, so `r4_BtoJ` has B, C, D, … J. A core with a single option is `r4_B`.
- **Rings** (Logan's pipelined cores): `ring<N>` = a ring holding N Spongent rounds in total (S stages × K rounds per
  stage), the number that sets long-message throughput: `ring40` (20×2), `ring20` (10×2), `ring16` (16×1). S, K and the
  keystream FIFO depth D are in each folder's `defines.txt` (`DUMBO_S/K/D`). His iterative core keeps `r4`.
- **Merged cores**: `ring<N>_<our options>` lists only the options added to his ring (`ring40_IL` = `ring40` + our I
  and L; `ring32_ILN` = a 16×2 ring with two entry points, option N, on top of I and L). Our core with his idea keeps
  our name (`r2_BtoM`). Until 2026-11-24 the rings were named by Logan's configuration, `pipe<S>x<K>d<D>`
  (`pipe20x2d16_IL`, …); `RENAMES.csv` maps them, and the SystemVerilog file headers still use those names.
- Options K–N have no section in ACCELERATION.md yet; their tables and each core's `README.md` describe them.

## Every core
Numbers: Vivado on xc7a100tftg256-2L (see the root README's Benchmarking section); long-message plaintext
throughput; cycles per 20-byte PT block on long messages; cycles for a 16 B plaintext message. Source:
`reports/benchmark.csv`.

| Core | Builds on | Status | Fmax (MHz) | LUT | Mbps | Kbps/LUT | cyc/block | cyc 16 B |
|---|---|---|---|---|---|---|---|---|
| [gmu/arch1_v1](gmu/arch1_v1/) | GMU arch-1 | v1 control: must always pass | – | – | – | – | – | – |
| [brody/base_r10](brody/base_r10/README.md) | gmu/arch1_v1 (ported to v2) | **baseline** (R = 10) | 90.5 | 2918 | 539 | 185 | 26.85 | 53 |
| [brody/base_r1](brody/base_r1/README.md) | brody/base_r10 | reference | 168.3 | 1534 | 158 | 103 | 170.22 | 269 |
| [brody/base_r4](brody/base_r4/README.md) | brody/base_r10 | reference; start of the r4 path | 166.3 | 1808 | 524 | 290 | 50.74 | 89 |
| [brody/base_r5](brody/base_r5/README.md) | brody/base_r10 | reference | 152.7 | 2042 | 571 | 280 | 42.78 | 77 |
| [brody/base_r8](brody/base_r8/README.md) | brody/base_r10 | reference | 115.5 | 2596 | 599 | 231 | 30.83 | 59 |
| [brody/base_r16](brody/base_r16/README.md) | brody/base_r10 | reference | 58.5 | 3874 | 448 | 116 | 20.87 | 44 |
| [brody/r4_B](brody/r4_B/README.md) | base_r4 | path: I/O overlap | 184.3 | 1882 | 689 | 366 | 42.81 | 87 |
| [brody/r4_BtoC](brody/r4_BtoC/README.md) | r4_B | path: two units | 169.5 | 2736 | 1247 | 456 | 21.74 | 87 |
| [brody/r4_BtoD](brody/r4_BtoD/README.md) | r4_BtoC | path: 2-stage pipeline | 147.8 | 4732 | 2175 | 460 | 10.87 | 89 |
| [brody/r4_BtoE](brody/r4_BtoE/README.md) | r4_BtoD | path: staggered calls | 163.8 | 5639 | 2652 | 470 | 9.88 | 88 |
| [brody/r4_BtoF](brody/r4_BtoF/README.md) | r4_BtoE | path: fast loader | 162.4 | 5631 | 2629 | 467 | 9.88 | 87 |
| [brody/r4_BtoG](brody/r4_BtoG/README.md) | r4_BtoF | path: 8 slots | 161.2 | 7295 | 5219 | 715 | 4.94 | 90 |
| [brody/r4_BtoH](brody/r4_BtoH/README.md) | r4_BtoG | path: stage-0 loads | 174.6 | 5496 | 5653 | 1029 | 4.94 | 90 |
| [brody/r4_BtoI](brody/r4_BtoI/README.md) | r4_BtoH | path: registered handshakes | 182.5 | 5467 | 5909 | 1081 | 4.94 | 92 |
| [brody/r4_BtoJ](brody/r4_BtoJ/README.md) | r4_BtoI | **final of the r4 path** | 182.4 | 5396 | 5906 | 1094 | 4.94 | 92 |
| [brody/r2_BtoH](brody/r2_BtoH/README.md) | r4_BtoH at 2 rounds/stage | comparison: worse than r4_BtoH | 171.4 | 5786 | 5549 | 959 | 4.94 | 150 |
| [brody/r2_BtoL](brody/r2_BtoL/README.md) | attic/brody/r2_BtoK | **final of the r2 path**; best of our own cores | 208.0 | 5742 | 6734 | 1173 | 4.94 | 152 |
| [brody/gen](brody/gen/README.md) | r4_BtoD, parameterized | design-space sweep core | 150.7 | 5139 | 2121 | 413 | 11.37 | 90 |
| [attic/brody/r2_BtoI](attic/brody/r2_BtoI/README.md) | r2_BtoH | superseded by r2_BtoL | 201.4 | 5852 | 6521 | 1114 | 4.94 | 152 |
| [attic/brody/r2_BtoJ](attic/brody/r2_BtoJ/README.md) | attic/brody/r2_BtoI | superseded by r2_BtoL | 197.6 | 5767 | 6398 | 1109 | 4.94 | 152 |
| [attic/brody/r2_BtoK](attic/brody/r2_BtoK/README.md) | attic/brody/r2_BtoJ | superseded by r2_BtoL | 204.2 | 5762 | 6611 | 1147 | 4.94 | 152 |
| [logan/r4](logan/r4/) | his iterative core | his, unmodified | 219.8 | 1391 | 706 | 508 | 49.78 | 106 |
| [logan/ring16](logan/ring16/) | his ring | his, unmodified | 210.3 | 3500 | 3355 | 959 | 10.03 | 262 |
| [logan/ring20](logan/ring20/) | his ring | his, unmodified | 215.4 | 3666 | 4242 | 1157 | 8.12 | 142 |
| [logan/ring40](logan/ring40/) | his ring | his, unmodified | 222.5 | 5552 | 7162 | 1290 | 4.97 | 142 |
| [merged/ring40_I](merged/ring40_I/README.md) | logan/ring40 | superseded by ring40_IL | 245.2 | 5607 | 7892 | 1408 | 4.97 | 144 |
| [merged/ring40_IL](merged/ring40_IL/README.md) | merged/ring40_I | fastest core | 249.2 | 5700 | 8021 | 1407 | 4.97 | 144 |
| [merged/ring20_IL](merged/ring20_IL/README.md) | logan/ring20 | smaller ring with I, L | 244.1 | 3865 | 4807 | 1244 | 8.12 | 144 |
| [merged/ring32_ILN](merged/ring32_ILN/README.md) | merged/ring40_IL | **best Kbps/LUT of all cores** | 247.1 | 5176 | 8000 | 1546 | 4.94 | 144 |
| [merged/r2_BtoM](merged/r2_BtoM/README.md) | brody/r2_BtoL + Logan's no-delay-line idea | tried, not adopted | 200.8 | 5725 | 6501 | 1136 | 4.94 | 152 |

`brody/base_r4` did not close timing at its best target (`not_closed` in `reports/benchmark.csv`), and
`brody/gen`'s numbers predate its last RTL change (`cycles_stale synth_stale`); use `reports/sweep/` for it.
