# core_v2_logan_pipe20x2d16_optIL: Logan's 20×2 ring with our options I and L

On top of [core_v2_logan_pipe20x2d16_optI](../core_v2_logan_pipe20x2d16_optI/OPT_I.md). Two changes:

1. **Key slice** (`CryptoCore_slice_shim.sv`): a 2-entry register slice on the key channel too (`key`,
   `key_update`), so no wrapper signal reaches his logic in the same cycle. His core reads `key_valid` only as a
   trigger in `S_IDLE` (the word stays at the head until `S_KEY` takes it) and in `S_KEY`'s `adv`.
2. **Our option L inside his core** (this directory's copy of `CryptoCorePipe.sv`, from rtl/logan/ at commit
   74a0ef4; changes marked `optIL`): the data selects of the 160-bit `KB` (keystream block) and `TI` (call
   waiting for a ring slot) come from registers, and the handshake-derived `kb_load` / `take` / `comp` drive
   only their enables.
   - `KB <= (!kb_v || tw == 4) ? ksf_head : rotate(KB)` when `kb_load || (take && st == S_MSG)`. Differs from
     the original only when a block's last word is taken while no keystream block is ready: `kb_v` drops to 0
     that cycle and `KB` is not read (`bdi_ready`, `bdo_valid` need `kb_v`) until the next `kb_load`.
   - `TI <= (st == S_FIN) ? ACC ^ KSTAR : ts_full ^ cmask`; `comp` never happens in `S_FIN`, so this is exact.

Why: optI's critical path was PreProcessor → `key_valid` → his shared `adv` / `comp` (fanout 335) →
`kb_load` (fanout 163) → the 160 `KB` enables.

## Results (2026-11-23)
- Validation: `make sim-all` passes random 1000, edge 374, full33 2178, long 10, badtag 374; `make cycles`
  checks all 81 vectors. Against optI: 27 encryptions take one more cycle (the key slice), the other 27 and
  all 27 decryptions the same; cycles per long block unchanged (4.97).
- `make synth` (from 4.117 ns, where optI closed): **249.2 MHz, 5700 LUT, 5534 FF** (optI: 245.2 MHz, 5607
  LUT, 5467 FF). Runs: 4.117 met (+0.104, 249.2 MHz achieved); 3.692 failed by 0.377 (245.8 MHz achieved);
  4.272 met (237.5 MHz achieved).
- Throughput at 249.2 MHz: **8021 Mbps long PT** (optI 7892, base 7162), **1407 Kbps/LUT** (optI 1408);
  16 B PT 222 Mbps, 64 B 803.
- Critical paths: no wrapper → core path left. Closed run: `tw` → `need_pad` / `TI` / `rp` / `KB`, one-hot
  state → `ACC` (fanout), ring LFSR (`lf`, finish detection) → `ACC` / `HK`. Tight 3.692 ns run: the key
  slice's `kh_v` and the output slice's `os_v` → the same accept logic → `HC` / `KB` / `TI` / `rp`; and 7 ring
  paths now among the 1000 worst.

## Takeaways
- +1.6% clock for +1.7% LUT: throughput up, throughput per LUT flat, both within Vivado's spread. Option I
  gave almost all of the gain on this core; L adds little because his core already selects most data from
  registers (his `dw`, `raw`, `ts_word`), and what is left is the fanout of one shared accept decision
  (`adv` / `comp`) into many 160-bit enables.
- With ring paths appearing near 270 MHz, the design is close to its ceiling with this wrapper and flow.
  Further control work (duplicating `comp`, pre-registering per-register enables) has at most a few percent
  left.
