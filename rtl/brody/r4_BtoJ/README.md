# brody/r4_BtoJ: a smaller source and mask select

Option J on top of [brody/r4_BtoI](../r4_BtoI/README.md). An area-only
change to the logic that builds each new call's input, `x = source ⊕ mask`. Same cycles, same clock.
At 2 rounds per stage: [attic/brody/r2_BtoJ](../../attic/brody/r2_BtoJ/) (same RTL, r2 constants).

## The logic J shrinks
In I, the datapath decoded the call's 3-bit kind into a 3-way source select and a 5-way mask select:

| Kind | Source | Mask |
|---|---|---|
| KEY | ib(0) | 0 |
| AD | ib(b) | φ^j (`wm0`) |
| MAC | ib(b) | φ^k ⊕ φ^(k+2) (`wm0 ⊕ wm2`) |
| KS | N ‖ 0 | φ^k ⊕ φ^(k+1) (`wk0 ⊕ wk1`) |
| FIN | tag | L |

Per state bit that is 9 data inputs (ib0, ib1, nonce, tag, wm0, wm2, wk0, wk1, L) plus the kind and buffer
bits: Vivado mapped it to 802 LUT cells for 160 bits (about 5 per bit), for `xr` and for the mask that goes
into the delay line.

## What changes (vs brody/r4_BtoI)
- Every mask is the XOR of two terms from fixed groups: **A** ∈ {0, `wm0`, `wk0`, L} and
  **B** ∈ {0, `wm2`, `wk1`}. So `mask = A ⊕ B` and `x = source ⊕ A ⊕ B`, with the source, A and B each a 4:1
  mux on its own 2-bit select.
- `CryptoCore.vhd`: the issue decision registers the three selects (`iss_src`, `iss_ma`, `iss_mb`) next to
  the call's kind. They are ready at the start of stage A, as the kind was.
- `elephant_datapath.vhd`: the three `with … select` muxes and the two XORs replace the kind decode;
  the `iss_kind` / `iss_buf` ports are gone (the issue engine still uses `iss_kind` for the LFSR steps).

Per bit: source (LUT6), A (LUT5), B (LUT4), and `x` / mask (LUT3 + LUT2, one site): 4 cells instead of 5.

## Results (2026-11-22)
- Validation: `make sim-all` passes random 1000, edge 374, full33 2178, long 10, badtag 374; `make cycles`
  checks all 81 vectors; cycle counts identical to r4_BtoI on all 81. `make profile WL=long`: 1683.
- `make synth`: **182.4 MHz, 5396 LUT, 3530 FF** (I: 182.5 MHz, 5467 LUT, 3536 FF). Closed at 5.546 ns;
  runs: 5.600 met (180.5 MHz achieved, 5418 LUT), 5.282 failed by 0.185 ns.
- Area: the source / mask logic is **640 LUT cells instead of 802** (−162, the predicted 5 → 4 per bit); in
  LUT sites the datapath and the mask LFSRs went from 2279 to 2218, and the total from 5467 to 5396 (−71,
  −1.3%). Vivado now files this logic under `MAC_LFSR` instead of `KS_LFSR` (hierarchy is flattened, so the
  per-instance numbers move around; the sum is what changed).
- Throughput: 5906 Mbps long PT, **1094 Kbps/LUT** (I: 1081); 16 B PT 254 Mbps.

## Takeaways
- A real but small saving: −1.3% LUTs, which is about Vivado's run-to-run LUT spread (±100 between targets
  for the same RTL). The cell counts confirm it is the intended logic that shrank.
- What's left outside the rounds is mostly one or two LUTs per bit for logic the algorithm needs (load
  mux, result mux, two LFSR windows, keystream head, tag accumulate, unmask XOR). The rounds are about 6%
  above their packing floor. There is no further area step of this size I know of without changing the
  architecture.
