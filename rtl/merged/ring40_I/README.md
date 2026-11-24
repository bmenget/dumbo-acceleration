# merged/ring40_I: Logan's 20×2 ring behind our option I

Logan's `CryptoCorePipe` (rtl/logan/src/, unmodified; S = 20, K = 2, D = 16 from `defines.txt`) with our option I
(see [brody/r4_BtoI](../../brody/r4_BtoI/README.md)): 2-entry register slices between the
LWC wrapper and the core, in `CryptoCore_slice_shim.sv` (module `CryptoCore`, replacing his
`CryptoCore_pipe_shim.sv`). Compared against [logan/ring40](../../logan/ring40/).

## Why
In our flow his ring has a lot of slack (no ring path among the 1000 worst at 4.134 ns); the clock was set by
the wrapper's handshakes reaching his 160-bit registers: PreProcessor state → `bdi_valid` → his loader's
`adv` / `take` / `comp` → the enables of `KB`, `TI`, `HC`, `TS`, `MI` and the FIFO pointer `rp` (5 levels, ~80%
routing). He also has two combinational pass-throughs: `bdo_valid` / `bdo` from `bdi_valid` / `bdi`
(CryptoCorePipe.sv line 211) and `bdi_ready` from `bdo_ready` (line 186).

## What the shim does
- Input slice on `bdi` with every side signal (`bdi_pad_loc`, `bdi_valid_bytes`, `bdi_size`, `bdi_eot`,
  `bdi_eoi`, `bdi_type`, `decrypt_in`, `hash_in`): `bdi_ready` to the wrapper is a flip-flop; the core sees a
  registered word. Transparent because the core reads those signals only with `bdi_valid` / `take` / `adv`,
  or (`decrypt_in` in `S_MSTART`) while the word is still at the head, not yet taken.
- Output slice on `bdo` (with `bdo_type`, `bdo_valid_bytes`, `end_of_block`): `bdo_valid` to the wrapper is a
  flip-flop; the core's `bdo_ready` is the registered "slice has room".
- The key channel and `msg_auth*` (already registered in his core) are not sliced, as in our option I.
- The instance stays `u_core`, so `profile.txt` (ring probes) is unchanged.

## Results (2026-11-23)
- Validation: `make sim-all` passes random 1000, edge 374, full33 2178, long 10, badtag 374; `make cycles`
  checks all 81 vectors. Against the base: encryptions take 1 or 2 more cycles (27 each), decryptions 1 more
  (all 27); cycles per long block unchanged (4.97).
- `make synth` (from 4.497 ns, the base's closing period): **245.2 MHz, 5607 LUT, 5467 FF** (base: 222.5 MHz,
  5552 LUT, 5293 FF). Runs: 4.497 met (+0.022, 223.5 MHz achieved); 4.117 met (+0.039, 245.2 MHz);
  3.752 failed by 0.286 (247.6 MHz achieved); 4.240 failed by 0.096.
- Throughput at 245.2 MHz: **7892 Mbps long PT** (+10.2%), **1408 Kbps/LUT** (+9.1%); 16 B PT 218 Mbps
  (base 201), 64 B 790 (base 726).
- Critical paths now (4.117 ns run): PreProcessor → `KB` / `TI` / `HC` / `rp` through the **unsliced key
  channel** (`key_valid` feeds his `adv` in `S_KEY`, which shares logic with the message `adv` / `comp`);
  `tw → TI` and `st → wp` / `rp` inside his core (4–5 levels, mostly routing). Still no ring path in the 1000
  worst.

## Takeaways
- +10% clock from the slices alone, for +55 LUT and +174 FF: the largest single gain of any change measured
  on either code base since option I itself. His core was where ours was before I.
- Next limits are within a few percent of each other: slicing the key channel too removes the remaining
  wrapper → core paths, but `tw → TI` (his word counter into the 160-bit tag-input register) is at the same
  slack, so further gains need L-style changes inside his core (register the `comp` / `kb_load` decisions a
  cycle ahead, or duplicate the high-fanout enables).
