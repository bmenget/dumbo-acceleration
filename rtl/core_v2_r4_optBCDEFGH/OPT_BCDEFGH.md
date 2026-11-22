# core_v2_r4_optBCDEFGH: less area at the same cycles

Option H on top of [core_v2_r4_optBCDEFG](../core_v2_r4_optBCDEFG/OPT_BCDEFG.md). G reached the 32-bit bus
limit on both PT and AD. H keeps every cycle count and cuts the area around the rounds.
[core_v2_r2_optBCDEFGH](../core_v2_r2_optBCDEFGH/OPT_BCDEFGH_R2.md) is the same RTL at 2 rounds per stage.
[core_v2_r4_optBCDEFGHI](../core_v2_r4_optBCDEFGHI/OPT_BCDEFGHI.md) takes the wrapper handshake off its critical path.

## Where G's area went
From a per-cell breakdown of G (`report_utilization -hierarchical` and `cells.tsv`, both now written by
`scripts/vivado_build.tcl`), 7295 LUT sites. The LUT numbers below count LUT *cells*: Vivado packs two
small cells (e.g. two 4-input S-box bits) into one LUT site, so they add up to more than the site total.

| Part | LUT cells | FF |
|---|---|---|
| 32 rounds (4 per stage register × 8) | 5200 | – |
| Load mux in front of every stage register (xr / ring) | 1280 | 1280 |
| Mask store read (8:1) and result (8:1) | 640 + 320 F7 | 1280 + 320 |
| x and mask select (`xr`, `mr`) | about 800 | 320 |
| Wrapper (PreProcessor, PostProcessor, header FIFO) | about 250 | 146 |

The rounds are fixed by the need for 32 rounds per cycle. The load mux and the two 8:1 muxes are there
only because a new call could go into any stage register.

## What changes (vs core_v2_r4_optBCDEFG)
- **New calls go into stage 0 of a ring only.** With `PERM_CYCLES` a multiple of `NSTAGE` (20 / 4 here),
  a call loaded in stage 0 always finishes in the ring's last stage, and the edge that ends it brings its
  slot back to stage 0. So a finished slot is still reusable at once. The issue engine only considers
  stage-0 registers.
  - Stages 1.. have no load mux: they take the previous stage's output directly.
  - The result is taken from the last stage of a ring: an `NUNIT`:1 mux (2:1 here) instead of 8:1.
- **Mask delay line instead of a mask store.** Every call takes exactly `PERM_CYCLES` cycles from load to
  finish, and loads are one per cycle, so calls finish in the order they were loaded. Each mask goes into
  a `PERM_CYCLES`-deep shift register (no reset, no enable, so Vivado maps it to SRLs). The indexed mask
  store, its 8:1 read mux, its write enables and the ring phase (`ph`, `vslot`) are gone.
- **Shape 2 × 4 instead of 4 × 2.** With stage-0 loads, fewer rings means fewer load muxes and a
  smaller result mux. 4 × 2 and 2 × 4 measure the same cycles. (1 × 8 isn't possible at 4 rounds per
  stage: 20 is not a multiple of 8.)
- **Keystream FIFO writes on every push.** The store's write enable is `ks_push` alone (a registered
  result); when the pushed keystream goes straight into an empty head, the read pointer skips its copy.
  Before, the write enable also depended on `ks_pop`, which comes from the wrapper handshake through the
  loader; that was H's worst path in a first build (−0.29 ns at 5.207 ns).

## Results (2026-11-20)
- Validation: `make sim-all` passes random 1000, edge 374, full33 2178, long 10, badtag 374; `make cycles`
  checks all 81 vectors.
- `make cycles`: identical to optBCDEFG: per PT block **4.93**, per AD block 5.00; 1536 B PT 470; 16 B PT
  90; 64 B PT 105.
- `make profile WL=long`: 1687 cycles, same as optBCDEFG.
- `make synth`: **174.6 MHz, 5496 LUT, 3370 FF** (optBCDEFG: 161.2 MHz, 7295 LUT, 4841 FF). Closed at
  5.769 ns and reproduced by a second single-period run (`scripts/synth.py --period0 5.769 --max-iter 1`).
  5.667 ns missed by 0.053 ns; searches started from 5.5 ns fell back to 158.5 MHz (a 5.845 ns run missed by
  0.111 ns, looser than one that met: Vivado noise). A first build, before the keystream FIFO change,
  closed at 177.0 MHz with 5396 LUT, so the change costs nothing measurable.
- Area vs optBCDEFG, in LUT cells from `cells.tsv` (G at 6.266 ns, H at 5.769 ns; H has 7899 LUT cells in
  5496 LUT sites):

  | Part | optBCDEFG | optBCDEFGH |
  |---|---|---|
  | Rounds (LUT sites, `util_hier.rpt`) | 3832 | 2819 |
  | Rounds (LUT cells) | 5200 LUT | 5040 LUT |
  | Stage registers `r` (load mux) | 1280 LUT, 1280 FF | 320 LUT, 1280 FF |
  | Result (`res`) | 674 LUT + 323 F7, 331 FF | 166 LUT, 327 FF |
  | Mask store `mst` / delay line `md` | 1280 FF | 160 SRL + 256 LUT (incl. mask select) |
  | x / mask select (`xr`, `mr`) | 802 LUT, 320 FF | 546 LUT, 160 FF (+ `md` above) |
  | Total (sites) | 7295 LUT, 4841 FF | 5496 LUT, 3370 FF |

  −1799 LUT (−25%), −1471 FF (−30%). The rounds take 2819 LUT sites (51%), about 88 per round against a
  floor of 80 (40 S-boxes × 4 output bits, two bits per LUT6 site). The other half is the support around
  them: source and mask select with the XOR (`xr`, `mr`), the two mask LFSR windows, the stage-0 load
  muxes, result, tag, keystream FIFO, control and wrapper. In G the same rounds took 3832 sites (less of
  the round logic packed two cells per site; the cause wasn't isolated).
- Throughput at 174.6 MHz: **5653 Mbps long PT**, 5571 Mbps long AD, **1029 Kbps/LUT** (optBCDEFG 715,
  ×1.44; optBCDEF 467, ×2.2; core_v2 ×5.6); 1536 B PT 4565 Mbps; 16 B PT 248 Mbps.
- Critical path: no longer the rounds. The top paths are the frozen wrapper's PreProcessor
  (`decrypt_internal`, `FSM_onehot_pr_state`) through the loader's handshake into `dp/ib` and `dp/kh`
  (7–8 levels, 78% routing). The round path, `r` → 4 rounds → 2:1 result mux → `res`, has 0.15 ns of
  slack at 5.769 ns (5 levels). Removing the 8:1 result mux is what moved the clock.

## Takeaways
- Same cycles as optBCDEFG, 25% fewer LUTs and an 8% faster clock: H is the best design point so far on
  every metric except area against the small single-unit cores.
- The clock is now set by the wrapper → core handshake (`bdi_valid`/`bdi_ready` decoding in the loader),
  at about 175 MHz. Fewer rounds per stage can't raise it:
  [core_v2_r2_optBCDEFGH](../core_v2_r2_optBCDEFGH/OPT_BCDEFGH_R2.md) has the same wrapper path on top
  and reaches 171.4 MHz with more area.
- What's left is short messages (16 B: 90 cycles) and the 5040 LUTs of rounds, which the bus limit
  requires (32 rounds per cycle).
- Headroom on the clock is small. Below the wrapper → core paths (PreProcessor → loader word-accept →
  `dp/ib`, `dp/kh`, and through the combinational `bdo_valid` into the PostProcessor FSM), the next paths
  are the rounds themselves: `r` → 4 rounds → `res` / `r` with 0.15 ns of slack at 5.769 ns and 0.04 ns at
  5.667 ns. Taking the whole handshake off the path would allow about 5.63 ns (177.5 MHz, +1.7%), inside
  Vivado's run-to-run noise. Not attempted: the word-accept signal depends on loader state that itself
  depends on the previous accept, so registering it moves the path rather than removing it.
  *Update:* a single register does, but a 2-entry register slice on each handshake removes it, and the
  rounds turned out to have more room than this estimate:
  [core_v2_r4_optBCDEFGHI](../core_v2_r4_optBCDEFGHI/OPT_BCDEFGHI.md) closes at 182.5 MHz (+4.5%).
