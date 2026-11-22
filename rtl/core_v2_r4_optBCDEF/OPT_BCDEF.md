# core_v2_r4_optBCDEF: staggered calls + fast loader

Option F on top of [core_v2_r4_optBCDE](../core_v2_r4_optBCDE/OPT_BCDE.md). Only `CryptoCore.vhd`
changes; the datapath, LFSRs, constants and issue engine are the same as optBCDE.
[core_v2_r4_optBCDEFG](../core_v2_r4_optBCDEFG/OPT_BCDEFG.md) doubles the slots on top.

## What changes
The loader used to spend a decision cycle after each block (`data_cnt = BLOCK_SIZE`): mark the buffer
full, pop the keystream, switch to the other buffer. A block took 6 cycles for its 5 words.

Now all of that happens in the cycle the block's last word goes in. The loader works out the block's
end state (`done_state` / `append_one` after this word, held in variables) and, if the other buffer is
free, starts the next block at word 0 the next cycle. If it isn't free, the loader waits in
`data_cnt = BLOCK_SIZE+1`.

One side effect: block 0 (N‖AD0) initializes the tag from buffer 0, which is still taking its last word
in that cycle, so the tag initialization is delayed one cycle (`tag_init_d`). Nothing reads the tag that
early.

This is the same idea as `G_FAST_LOADER` in [core_v2_gen](../core_v2_gen/GEN.md), applied to the
staggered loader.

## Results (2026-11-20)
- Validation: `make sim-all` passes random 1000, edge 374, full33 2178, long 10, badtag 374; `make cycles`
  checks all 81 vectors.
- `make cycles`: per AD block 6.02 (optBCDE) → **5.01**, the 32-bit bus limit of 5. Per PT block stays
  **9.88**: the 4 slots, not the loader, set the pace. 1536 B PT 848 → 847; 16 B PT 88 → 87; 64 B PT
  118 → 116.
- `make profile WL=long`: 2616 (optBCDE) → **2476** cycles (−5%; −15% vs optBCD). All four registers hold a
  call 91.2% of the time.
- `make synth`: **162.4 MHz, 5631 LUT, 3430 FF** (optBCDE: 163.8 MHz, 5639 LUT), so the fast loader is
  free in area and timing. The first search (`PERIOD0` from the predictor) ended at 143.3 MHz: its tight
  runs missed by 0.85 and 0.045 ns and the next met run was at 7.077 ns. Re-run with `PERIOD0=6.2`: met
  6.187, failed 5.935, met 6.162 ns.
- Throughput at 162.4 MHz: 2629 Mbps long PT (×1.21 vs optBCD), **5182 Mbps long AD** (×1.42 vs optBCD,
  ×1.19 vs optBCDE), 467 Kbps/LUT; 16 B PT 239 Mbps.
- Critical path: same as optBCDE, the 4 rounds into the 4:1 result mux (`core/pc` → `dp/res`, 7 levels),
  then the wrapper (0.9%) and wrapper → core (1.9%).

## Takeaways
- AD is now at the bus limit; nothing left to gain there without a wider bus.
- Plaintext is slot-bound (10 cycles per block at 4 slots). More slots, i.e. more units, are the next
  lever; with staggering, adding slots no longer adds a wider batch or tag XOR.
