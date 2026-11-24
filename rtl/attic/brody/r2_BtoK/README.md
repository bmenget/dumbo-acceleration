# attic/brody/r2_BtoK: no combinational path through the core

Option K on top of [attic/brody/r2_BtoJ](../r2_BtoJ/README.md) (2 rounds per
stage, 2 × 8 stages). A timing-only change to `CryptoCore.vhd`; the datapath is untouched.

## The path K removes
The r2 I and J notes put the clock down to "the frozen wrapper's own paths". The timing report of r2 J
(`build/synth/attic/brody/r2_BtoJ/p5.060/timing.rpt`) shows the critical path does go from wrapper to wrapper,
but **through the core**: PreProcessor state → `key_valid` → core control → tag word on `bdo_s` → the 32-bit tag
compare (3 CARRY4) → `msg_auth` → PostProcessor state. 12 levels, 5.02 ns. In J's `TAG_S` (decrypt) state,
`msg_auth` and `msg_auth_valid` were computed in the cycle of the last tag word, from `msg_auth_ready` (a
PostProcessor output) and the compare `bdi_i /= bdo_s`. It was the only wrapper → wrapper path through the core.

The idea comes from Logan's `CryptoCorePipe` (rtl/logan/src/), whose worst path with the same wrapper is 5 levels:
its `msg_auth` / `msg_auth_valid` come from registers.

## What changes (vs attic/brody/r2_BtoJ)
- `TAG_S`, decrypt: each received tag word is taken as soon as it is in the input slice (no longer waits for
  `msg_auth_ready`); its compare only clears the `tag_verified` register. After the last word: new state `AUTH`.
- `AUTH`: `msg_auth_valid = '1'` and `msg_auth = tag_verified`, both from registers, until `msg_auth_ready`;
  then `IDLE`.
- `key_ready` is high whenever `STORE_KEY` wants a key word, no longer gated by `key_valid` (the LWC
  handshake allows ready before valid). After K, every core output is a register or a decode of registers.

Cost: one cycle per decryption (the `AUTH` cycle). Encryption is unchanged.

## Results (2026-11-23)
- Validation: `make sim-all` passes random 1000, edge 374, full33 2178, long 10, badtag 374; `make cycles`
  checks all 81 vectors. Against J: all 54 encryptions take the same cycles, all 27 decryptions exactly one
  more. `make profile WL=long`: 1783 (as J).
- `make synth` (from 5.060 ns, as J's search): **204.2 MHz, 5762 LUT, 4931 FF** (J: 197.6 MHz, 5767 LUT,
  4928 FF). Runs: 5.060 met (+0.135, 203.0 MHz achieved), 4.531 failed by 0.201 (211.3 MHz achieved),
  4.969 met (+0.071, 204.2 MHz).
- Throughput at 204.2 MHz: 6611 Mbps long PT (+3.3%), **1147 Kbps/LUT** (J: 1109); 16 B PT 172 Mbps.
- Critical path now (`python3 scripts/critpath.py --core attic/brody/r2_BtoK`): no wrapper → wrapper path is
  left. The worst is `ih_v → ib` (input slice valid → input buffer, 6 levels, 79% routing), then
  PreProcessor → core input slice (2.4% behind), `ih → kh` (keystream head), then the control (10% behind).

## Takeaways
- The path is gone and the clock rose as predicted (about +4% to the next path; measured +3.3%). That is
  inside Vivado's search-to-search spread (r2 I reached 201.4 MHz, J 197.6), so treat the gain as small but
  real: the 12-level path no longer exists, and the next limits are all inside the core.
- To approach Logan's 222.5 MHz with the same wrapper, the next target is the loader's write into the input
  buffers (`ih_v` / `ih` → `ib`, and `ih` → `kh`): the input slice's valid and word fan out to 160-bit
  buffer enables through the loader's decisions.
