# brody/gen: parameterized core for the design-space sweep

One Dumbo v2 core whose structure is set by four constants in `elephant_constants.vhd`. It generalizes
`brody/r4_BtoD` (options B, C and D of [../ACCELERATION.md](../../ACCELERATION.md)). `scripts/sweep.py`
rewrites the constants for each design point in a temporary folder. The checked-in values are R=8, S=2,
U=2, which is r4_BtoD's configuration, so `make sim-all CORE=brody/gen` / `make cycles CORE=brody/gen` work
for manual checks.

| Constant | Meaning | Range |
|---|---|---|
| `G_R` | rounds of logic per unit (unrolling) | 1–16 |
| `G_S` | pipeline stages per unit; must divide `G_R` | 1–4 |
| `G_U` | units | 1, 2, 4, 8 |
| `G_FAST_LOADER` | decide the next block buffer in the same cycle as a block's last word | `false` / `true` |

Derived (also computed by `sweep.py`):

| Name | Formula | Meaning |
|---|---|---|
| `G_RPS` | R/S | rounds per stage: the permutation's share of the clock period |
| `G_N` | U·S | permutation calls in flight (slots) |
| `G_M` | ⌊N/2⌋ | message blocks per round (M MACs alongside M keystreams) |
| `PERM_CYCLES` | ⌈80/RPS⌉ | cycles per call |
| `G_TAIL` | 80 − (PERM_CYCLES−1)·RPS | rounds that count in the last pass (< RPS when RPS doesn't divide 80) |
| `G_ROT` | PERM_CYCLES mod S | how many stage registers a result ends up past where it was loaded |
| `G_NMASK` | max(3M+1, N, 3) | masks in the LFSR window (8 FF each beyond the first) |

**What each knob does:**
- **R** sets the round logic per unit.
- **S** only moves registers: each unit still computes R rounds per cycle, the critical path shrinks to
  R/S rounds, and each call takes S times longer, so S calls per unit must be kept in flight.
- **U** copies units.

## Structure
- **`elephant_stage.vhd`:** RPS Spongent rounds, combinational. Round constants are computed at
  elaboration from the 7-bit LFSR (any RPS works; this replaces GMU's fixed tables). A tap after `G_TAIL`
  rounds handles a last pass shorter than RPS.
- **`elephant_datapath.vhd`:**
  - **Units:** each is a ring of S stage registers. During PERM every register takes the output of the
    stage behind it, so all calls move together and every stage computes the same rounds each cycle.
  - **Results:** the call loaded into slot i ends in slot `res(i)` (offset `G_ROT` within its unit).
  - **Slot muxes:** a source and mask mux per slot, chosen by a registered `mode` (table in the file
    header).
  - **Buffers:** N input block buffers and max(M,1) keystream buffers.
  - **Tag:** an accumulator that XORs any subset of slot results.
- **`elephant_datapath_lfsr.vhd`:** a window of `G_NMASK` masks. Multi-steps of max(M,1), N, NMASK and
  NMASK−1 are the single step iterated at elaboration (linear, so they synthesize to XOR networks).
- **`CryptoCore.vhd`:** a block loader (batches of N AD blocks or max(M,1) message blocks) and a slot
  scheduler.
  - **Each permutation:** setup → PERM → POST1 (unmask in place + LFSR step) → POST2 (tag / keystream
    buffers).
  - **N = 1** runs option B's order (KS(k+1), then MAC(k) while block k+1 streams).

## Schedule
Window w(j) = φ^(a−1+j).

| Phase | Slots | Window / step |
|---|---|---|
| AD block 0 (N‖AD0) | none; tag ← block | LFSR load, then NMASK steps → a = 2 |
| AD batch j..j+N−1 | slot i: A_{j+i} ⊕ w(i) | a = j+1; step N |
| Message start (N ≥ 2) | slot i < 2M: KS(i) = N ⊕ w(i) ⊕ w(i+1); KS(0..M−1) → keystream buffers | LFSR reload, NMASK−1 steps → a = 1 |
| Message round, more follows (N ≥ 2) | slots i < M: MAC(k+i) = C ⊕ w(i) ⊕ w(i+2); slots M ≤ i < 2M: KS(k+M+i) = N ⊕ w(M+i) ⊕ w(M+i+1); keystream buffers ← KS(k+M..k+2M−1) at setup; blocks k+M.. stream meanwhile | a = k+1; step M |
| Last message round | MACs only | |
| N = 1 | KS(0); then per block: KS(k+1) (N ⊕ w1 ⊕ w2), MAC(k) (C ⊕ w0 ⊕ w2) while block k+1 streams | step 1 per MAC |
| Final | slot 0: P(tag ⊕ L) ⊕ L | |

## Differences from brody/r4_BtoD (expected to change cycle counts slightly)
- **POST is two cycles**, not one. Unmasking happens in place first, then the tag/keystream update, so the
  slot muxes and the N-wide tag XOR are never in one path. That's +1 cycle per round.
- **`mode`/`unmask` are registered.** They're decided one cycle early from the next state, with a
  `max_fanout` limit so Vivado replicates them instead of broadcasting one net to every slot.
- **The LFSR is set up in one load plus one multi-step** (r4_BtoD: load + 4/2/1 steps).
- **`G_FAST_LOADER` exists**; r4_BtoD always spends a decision cycle per block (= `false`).

## Status (2026-11-19)
- Compiles (Questa `vcom`). Elaborates (`vopt`, nothing simulated) for R/S/U = 1/1/1, 4/1/1, 3/3/1,
  12/1/1, 6/2/1, 4/2/3, 5/1/4 (fast), 16/4/8 (fast) and 8/2/2. These cover N = 1, odd N, a partial last
  pass, a non-zero result offset and the largest point.
- **Not simulated yet.** The next step is the manual check against r4_BtoD at the checked-in configuration
  (`make sim-all CORE=brody/gen`, `make cycles CORE=brody/gen`, `make synth CORE=brody/gen`) before any sweep.
