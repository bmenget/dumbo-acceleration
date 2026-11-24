# core_v2_r2_optBCDEFGHIJKLM: no mask delay line (tried, not adopted)

Option M on top of [core_v2_r2_optBCDEFGHIJKL](../core_v2_r2_optBCDEFGHIJKL/OPT_BCDEFGHIJKL.md). An area
experiment taken from Logan's `CryptoCorePipe` (rtl/logan/): drop the 40-deep mask delay line.

## What changes (vs core_v2_r2_optBCDEFGHIJKL)
Each call's mask was carried to its result through a PERM_CYCLES-deep delay line (`md`, 160 × 2 SRL32 at 2
rounds per stage) and `res_mask`. Instead, by kind:
- **AD / MAC:** results go into the tag unmasked; the masks are summed into `macc` when the call is loaded
  (stage B, `macc ^= mr`). The tag is an XOR sum, so FIN's input `tag ⊕ L ⊕ macc` is the v2 `S ⊕ L`. `macc`
  is the B mask term's spare 4th input (`iss_mb = "11"` for FIN), so that mux does not grow.
- **KS:** a second keystream window (`KSO_LFSR`, the same entity as `KS_LFSR`) gets the same load + 1 setup
  step and then steps once per KS result; results come back in load order, so each sees its issue window.
- **KEY:** no mask. **FIN:** L (`key_out`).
- `u = res`, `res ⊕ kso0 ⊕ kso1` or `res ⊕ L`, selected by `res_ms` (registered with `res_kind`).

## Results (2026-11-23)
- Validation: `make sim-all` passes random 1000, edge 374, full33 2178, long 10, badtag 374; `make cycles`
  checks all 81 vectors, every message the same cycles as L.
- `make synth` (from 5.060 ns, as J, K, L): **200.8 MHz, 5725 LUT, 5264 FF** (L: 208.0 MHz, 5742 LUT,
  4931 FF). Runs: 5.060 met (+0.080); 4.582 failed by 0.583; 5.321 met (186.2 MHz achieved).
- Area by cell type: SRLs 326 → 6, but LUT cells 8035 → 8300. The datapath's own LUTs fell by 667 (the
  delay line), while the new result mux (6 inputs per bit: res, two window bits, L, two selects; filed by
  Vivado under `KSO_LFSR`, 646 LUT) plus the second window and `macc` took almost all of it back. Net −17 LUT
  sites (−0.3%), +333 FF.
- Critical path: `ks_st → KS_LFSR/o` (1 level, 88% routing): `ks_st` now drives the setup of two 168-bit
  windows.

## Takeaways
- Not adopted: the delay line was cheap for what it did (an SRL32 holds 32 cycles of a bit in one LUT),
  and rebuilding masks by kind costs about as much as storing them, even at 40 cycles deep. In Logan's core
  the same idea pays because his datapath is organised around it (masks accumulated as words are assembled);
  bolted onto ours it does not.
- L stays the r2 core.
