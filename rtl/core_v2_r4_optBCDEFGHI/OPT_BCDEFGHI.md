# core_v2_r4_optBCDEFGHI: the wrapper handshake off the critical path

Option I on top of [core_v2_r4_optBCDEFGH](../core_v2_r4_optBCDEFGH/OPT_BCDEFGH.md). H's clock was set by
a path that started in the frozen wrapper and ended deep in our datapath. I cuts it with two register
slices and a restructured keystream head. Same RTL at 2 rounds per stage:
[core_v2_r2_optBCDEFGHI](../core_v2_r2_optBCDEFGHI/OPT_BCDEFGHI_R2.md).
[core_v2_r4_optBCDEFGHIJ](../core_v2_r4_optBCDEFGHIJ/OPT_BCDEFGHIJ.md) shrinks its source and mask select (−1.3% LUTs).

## The path I removes
H's worst path in the failing 5.667 ns run (7 LUT levels, 78% routing):

```
PreProcessor pr_state  (frozen wrapper)
 -> bdi_type decode             1 LUT (wrapper output, combinational)
 -> segment / first_blk checks  2 LUT
 -> ks_used / data_cnt          1 LUT
 -> ks_pop                      1 LUT, fanout 9
 -> kh enable logic             1 LUT, fanout 164
 -> kh_reg CE                   1 LUT, fanout 160
```

Only the first level is the wrapper. The rest is our loader turning "a word is accepted this cycle" into
the keystream head's enable, over two 160-wide fanouts. The 2-rounds-per-stage H had the same path plus a
loop back into the PreProcessor's own FSM through our combinational `bdi_ready`.

## What changes (vs core_v2_r4_optBCDEFGH)
- **Input register slice** (`CryptoCore.vhd`, `p_in_slice`): a 2-entry skid buffer between the PreProcessor
  and the loader. It carries `bdi`, `bdi_valid_bytes`, `bdi_size`, `bdi_eot`, `bdi_type` and the decrypt
  flag. `bdi_ready` is now a flip-flop (`not is_v`), and the loader decides on a registered word.
- **Output register slice** (`p_out_slice`): the same between the core and the PostProcessor, carrying `bdo`,
  `bdo_valid_bytes`, `bdo_type` and `end_of_block`. `bdo_valid` is a flip-flop, and the loader's "output has
  room" is a flip-flop (`not os_v`) instead of the PostProcessor's `bdo_ready`.
- **Segment check on the slice.** A segment is present when the slice's head word has the expected type.
  When the slice is empty, the loader still peeks at the wrapper's `bdi_type` (which shows the segment
  before its first word is valid) to tell an empty segment from a late one. That peek only feeds the
  segment-check state bits, never the word accept, so it adds no path into the datapath.
- **Keystream head: the accept is the last mux** (`elephant_datapath.vhd`). Both candidates for the next
  head, `kh_pop` (head dropped) and `kh_keep` (no word out), are built from registers only (push, count,
  store). The loader's `ks_pop` / `ks_adv` then only select among `kh_pop`, the head shifted by one word,
  and `kh_keep`.

The 2-entry slices run at full rate: one word per cycle in steady state, no bubble when the far side stalls.

## Results (2026-11-22)
- Validation: `make sim-all` passes random 1000, edge 374, full33 2178, long 10, badtag 374; `make cycles`
  checks all 81 vectors.
- `make cycles`: +1 or +2 cycles per message against H (the slices' latency, once per message, not per word);
  per PT block still **4.94**. 16 B PT 90 → 92; 64 B PT 105 → 107; 1536 B PT 470 → 472.
- `make profile WL=long`: 1683 cycles (H: 1687). The input slice absorbs a few of the wrapper's
  one-cycle bubbles.
- `make synth`: **182.5 MHz, 5467 LUT, 3536 FF** (H: 174.6 MHz, 5496 LUT, 3370 FF). Closed at 5.600 ns.
  The search runs: 5.041 ns missed by 0.106 ns (achieved 5.147 ns), 5.404 ns missed by 0.169 ns (achieved
  5.573 ns), 5.731 ns met with 0.399 ns. Vivado noise as before: the tighter target placed the rounds
  better than the looser one. A separate single run at 5.200 ns missed by 0.090 ns (achieved 5.290 ns,
  189 MHz); it is in `synth_runs.csv` but not used as the result, which must be a closed run.
- Area: +166 FF are the two slices (2 × 45 + 2 × 41 bits, unused bits trimmed). LUTs are within noise of H.
- Throughput at 182.5 MHz: **5909 Mbps long PT** (H 5653, +4.5%), 5823 Mbps long AD, **1081 Kbps/LUT**
  (H 1029, +5.1%); 1536 B PT 4751 Mbps; 16 B PT 254 Mbps (H 248: the clock gain outweighs the 2 cycles).
- Critical path: **the rounds**. `rc` / `r` → 4 rounds → next stage `r` or the 2:1 result mux into `res`
  (5–6 LUT levels, 70–75% routing). No wrapper or loader path is in the top five.

## Tool flow study (2026-11-22)
Same RTL, other Vivado flows (`scripts/synth.py --flow`, see `scripts/vivado_build.tcl`; runs in
`reports/flow_runs.csv`, results in `reports/flow_results.csv`, builds in `build/synth/<core>/<flow>/`).
Throughput and efficiency scale with Fmax (the cycles don't change).

| Flow | What changes | Fmax | LUT | Long PT | Kbps/LUT | 16 B PT |
|---|---|---|---|---|---|---|
| base (standard) | synthesis without a clock, default directives | 182.5 | 5467 | 5909 | **1081** | 254 |
| tsyn | clock read before synthesis (timing-driven) | 162.9 closed (184.6 missed by 0.017 ns) | 5598–5888 | 5274–5977 | 942–1015 | 227–257 |
| perf | tsyn + timing directives everywhere, post-route phys_opt | **191.2** | 6386 | **6190** | 969 | 266 |
| area | tsyn + AreaOptimized_high (no BRAM), opt ExploreArea | 169.8 | **5100** | 5498 | 1078 | 236 |

- The timing flows buy clock by replicating logic: perf is +4.8% Fmax for +17% LUTs (+32% at its 201.5 MHz
  try). tsyn alone is noise-level on the clock and adds LUTs.
- The area flow trades the other way at the same rate: −6.7% LUTs for −7% clock.
- On throughput per LUT, nothing beats the base flow, so all reported results stay on base (one flow for every
  core). perf (191.2 MHz) and area (5100 LUT) are the "fastest" and "smallest" builds of this RTL if a
  single-metric number is wanted.
- Notes: perf's third run (5.211 ns) crashed inside Vivado (segfault in the post-route
  `phys_opt_design -directive AggressiveExplore`); its result is closed by the search rule anyway (met 5.3 ns,
  failed 4.812 ns). A first area run without `-max_bram 0` moved the shift registers into 6.5 BRAM tiles and
  missed 5.6 ns by 0.8 ns.

## Takeaways
- H's clock limit was mostly our own handshake logic, not the wrapper. With it registered, the 4-round
  stages set the clock, as they should.
- The rounds themselves are about as short as they can be: one LUT level per round (each S-box output bit
  needs its 4 inputs), and Spongent's bit permutation spreads every round across the whole 160-bit state,
  so most of the delay is routing. Shorter stages are the remaining RTL lever, which is the 2-rounds-per-stage
  variant: 201.4 MHz, but 60 extra cycles on every short message.
- The slices cost one cycle each way per message. For a report table that leads with short messages, H's
  90 cycles for 16 B is one cycle better, but the faster clock still gives I the higher 16 B throughput.
