# brody/r2_BtoL: the input buffers' data select off the word accept

Option L on top of [attic/brody/r2_BtoK](../../attic/brody/r2_BtoK/README.md) (2 rounds per
stage, 2 × 8 stages). A timing-only change to `CryptoCore.vhd`.

## The path L removes
K's critical path (`build/synth/attic/brody/r2_BtoK/p4.969/timing.rpt`): `ih_v` → the loader's message
accept (slice valid, type, `ks_cnt /= 0`, output room) → `ks_adv` (fanout 167) → `saving_bdo` (fanout 32) →
`bdi_or_bdo` → padding / load mux → the D input of every `ib` bit. 6 levels, 79% routing.

`saving_bdo` selects what an input buffer stores for a message word: the ciphertext `bdo` (encrypt) or the
word `bdi` (decrypt). It was set inside the accept branch, so the accept decision reached the buffers' data
mux, not just their write enable.

## What changes (vs attic/brody/r2_BtoK)
- `saving_bdo = fill_active and fill_msg and (bdi_type_i = HDR_PT)`: registers only (the slice's head word).
- The assignment inside the accept branch is gone. The accept still drives `load_data_en` (the write enable).

Why it is the same function wherever `ib` is written: while the loader fills a message the only writes are
an accepted word (PT stores `bdo`, CT stores `bdi`: as before) or padding (constants that ignore
`bdi_or_bdo`). The main FSM writes `ib` only in `STORE_KEY` / `LOAD_NONCE`, with `fill_active = '0'`, where
`saving_bdo` is `'0'` as before.

## Results (2026-11-23)
- Validation: `make sim-all` passes random 1000, edge 374, full33 2178, long 10, badtag 374; `make cycles`
  checks all 81 vectors, every message the same cycles as K (54 encryptions, 27 decryptions).
- `make synth` (from 5.060 ns, as J and K): **208.0 MHz, 5742 LUT, 4931 FF** (K: 204.2 MHz, 5762 LUT).
  Runs: 5.060 met (+0.253, 208.0 MHz achieved); 4.422 failed by 0.140 (219.2 MHz achieved); 4.790 failed
  by 0.156 (202.2 MHz achieved: Vivado noise); 5.441 met (192.0 MHz achieved).
- Throughput at 208.0 MHz: 6734 Mbps long PT, **1173 Kbps/LUT** (K: 1147, J: 1109); 16 B PT 175 Mbps.
- Critical path of the closed run: `ih_v → kh` (keystream head), then `iss_mb → xr`. In the 4.422 ns run
  the failing paths are all on the input side and routing-bound (logic 0.8–0.9 ns of 3.9–4.5 ns):
  PreProcessor → `wait_cnt` (the loader's peek at the wrapper's `bdi_type`), `ih → ib`, the `ib` write
  enable, wrapper → input slice, `ih → kh`.

## Takeaways
- `ih_v → ib` is gone from the top paths; J → K → L is 197.6 → 204.2 → 208.0 MHz with the same cycles for
  encryption, 20 fewer LUTs than J and +5.7% Kbps/LUT. Each step is inside Vivado's search-to-search spread
  on its own; together they are a consistent trend, and each removed path is confirmed in the timing reports.
- Near 220 MHz the limits are many input-side paths of 4–7 levels, each mostly routing. Logan's 20×2 core
  closes at 4.497 ns (222.5 MHz) with the same wrapper; closing the remaining gap is now about fanout and
  placement of the loader's accept (into `ib`, `kh`) and the segment-wait peek, not one long path.
