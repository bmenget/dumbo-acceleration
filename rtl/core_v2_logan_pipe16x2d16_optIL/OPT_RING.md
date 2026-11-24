# core_v2_logan_pipe16x2d16_optIL: a 32-round ring with two entry/exit points

On top of [core_v2_logan_pipe20x2d16_optIL](../core_v2_logan_pipe20x2d16_optIL/OPT_IL.md) (Logan's ring + our
options I and L). Area change: 16 × 2 = 32 rounds instead of 20 × 2 = 40, at the same bus-limited throughput.
**Status: measured 2026-11-23 (results below): adopted.**

## Why 32 rounds, and why two points
- In his ring, cycles per 20-byte PT block = 160 / rounds until the 32-bit bus limit: measured 16×1 → 10.03,
  10×2 → 8.12, 20×2 → 4.97 (capped at about 5). Long messages need 2 calls × 80 rounds per block in 5 cycles,
  i.e. 32 rounds per cycle; 20 × 2 carries 8 rounds the bus cannot use.
- His ring needs S·K | 80 (a call leaves where it entered); 32 does not divide 80. At 16 × 2 a call needs
  80/K = 40 stage steps = 2.5 laps and finishes opposite its entry point. With one entry point its slot would
  ride empty for 8 cycles (about 6 cycles per block). With **two points 8 stages apart**, a call entering at one
  leaves at the other, and that point refills the slot in the same cycle.

## What changes (vs core_v2_logan_pipe20x2d16_optIL)
- `spongent_perm_pipe.sv` (this directory's copy): parameter `P` (entry/exit points, `S/P` stages apart;
  needs `80/K` a multiple of `S/P` and `S/P >= 2`). Each point has its own insertion mux and finish detector;
  a call is accepted at the lowest-numbered point whose slot is empty or finishing; the result comes from the
  point that finishes (2:1 mux into the registered `out_state`). Interface, fixed latency (80/K + 1) and
  in-order results are unchanged, so `CryptoCorePipe` needs nothing but the parameter. The finish flag of each
  point is now registered one cycle ahead (from the stage two before the point), which takes the LFSR compare
  off the accept / insertion-mux path; cycle behaviour is the same as before.
- `CryptoCorePipe.sv`: parameter `P`, passed to the ring. `CryptoCore_slice_shim.sv`: `DUMBO_P`.
- `defines.txt`: `DUMBO_S=16 DUMBO_K=2 DUMBO_D=16 DUMBO_P=2`.
- `profile.txt`: per-stage probes `u_ring/g_stage[s]/busy` (the single-point `ring` reconstruction in
  `scripts/profile.py` does not hold with two points). The VCD path of generate scopes is assumed; check it in
  the first `make profile`.

## Expected (to be measured)
- Area: base 20×2 vs 10×2 differ by 1886 LUT for 20 rounds (about 94 LUT per round with its stage overhead):
  −8 rounds ≈ −750 LUT and −680 FF; +160 (second insertion mux) +160 (result mux) +~30 (second finish
  detector, arbitration). Net about **−350 to −450 LUT** (−6 to −8% of 5700).
- Cycles: about 5.0 per long PT block, if the ring stays full (no spare rounds now: any bubble costs throughput).
- Fmax: about the 20×2 optIL's 249 MHz if the extra muxes stay off the critical paths (the ring had slack;
  the shared accept logic is near-critical).
- If both hold: about 5300 LUT, 8000 Mbps, **about 1500 Kbps/LUT** (20×2 optIL: 1407).

## Results (2026-11-23)
- Validation: `make sim-all` passes random 1000, edge 374, full33 2178, long 10, badtag 374; `make cycles`
  checks all 81 vectors. Against 20×2 optIL: 36 messages the same, 9 shorter (by 2 or 9 cycles), 36 longer
  (by 4–6 cycles, the most on 1536 B messages: +6 of about 1700). **Cycles per long PT block 4.94** (20×2: 4.97),
  AD 5.01: the ring stays full at 32 rounds. Profile (long workload): 1818 cycles (20×2 optIL 1810); the per-stage
  probes `g_stage[s]/busy` work.
- `make synth` (from 4.117 ns): **247.1 MHz, 5176 LUT, 4864 FF** (20×2 optIL: 249.2 MHz, 5700 LUT, 5534 FF).
  Runs: 4.117 met (+0.070, 247.1 MHz achieved); 3.723 failed by 0.162 (257.4 MHz achieved); 4.079 failed by
  0.260; 4.773 met (223.6 MHz achieved).
- Throughput at 247.1 MHz: **8000 Mbps long PT** (20×2 optIL 8021), **1546 Kbps/LUT** (20×2 optIL 1407, +9.8%;
  base 20×2 1290, +19.8%); 16 B PT 220 Mbps, 64 B 796.
- Area: **−524 LUT (−9.2%), −670 FF** against 20×2 optIL: more than the −350 to −450 estimated.
- Critical paths (4.117 ns run): unchanged in kind, `tw → TI / KB / HC / MI / TS` in the core (4–5 levels);
  ring paths now among the 1000 worst (78; the worst `lf → st`, 0.306 ns slack: round constants through two
  rounds and an insertion mux).

## Takeaways
- The right-sized ring keeps the bus-limited throughput (8.0 Gbps) in 9% fewer LUTs: the best throughput per
  LUT measured in this project (1546 Kbps/LUT), and the best Pareto point at about 5.2 k LUT.
- Clock: −0.8% against 20×2 optIL (within Vivado's spread); the second insertion and result muxes did not
  reach the critical path.
- Short messages are unchanged (call latency is still 80/K + 1 = 41 cycles; 16 B in 144 cycles).

## Checks for the first run (done)
- `make sim-all`, then compare `make cycles` with 20×2 optIL: long-block cycles must stay about 5.0.
- `make synth` from 4.117 ns (20×2 optIL's closing period), then `critpath`-style path listing for the new muxes.
