# brody/r4_BtoD: I/O overlap, two units, two pipeline stages per unit

Options B, C and D from [../ACCELERATION.md](../../ACCELERATION.md), on top of
[brody/r4_BtoC](../r4_BtoC/README.md). Each of the two units is an 8-round loop cut into two
4-round stages, so 4 permutation calls are in flight. Compare against `brody/r4_BtoC`.

**Read this first: what the pipelining buys.** Each pipeline stage is 4 rounds deep, the same depth as
r4_BtoC's units, so the clock target doesn't change. What doubles is the number of calls in flight (2 → 4).
With both calls of a unit loaded together, the two stage registers swap every cycle. Both stages always
process the same 4-round group (one round-constant ROM index), and after 20 cycles each call is back in the
register it started in.

That is **logically the same amount of hardware as four separate R=4 units**: 16 rounds of logic and 4 state
registers, each with its own load mux. The only difference is the cross wiring between a unit's two
registers. The speedup comes from 4 calls in flight, not from pipelining as such. (Splitting r4_BtoC's
existing 4 rounds into 2 + 2 stages would keep cycles per block the same and only help if the permutation
were the critical path, which it isn't.)

| File | vs `brody/r4_BtoC` |
|---|---|
| `elephant_datapath.vhd` | rewritten around 4 slots (A0, A1, B0, B1), each with an `elephant_perm` and a register; slots swap within a unit during PERM; one `mode` input picks every slot's source and mask, and `unmask` makes each slot's source its own register; 4 input block buffers; 2 keystream buffers; the tag XORs any subset of slots; `key_out` loads straight from the permutation output |
| `elephant_datapath_lfsr.vhd` | 7-mask window (208 bits) that can step by 1, 2 or 4 in one cycle (each new byte only reads original bytes) |
| `elephant_constants.vhd` | `LFSR_MASKS`, `LFSR_W`, slot-mux mode codes `MD_*` |
| `CryptoCore.vhd` | batch loader (2 blocks per round for the message, up to 4 for AD), registered `batch_done`, 4-slot scheduler with an `act` mask |
| `elephant_perm.vhd`, `design_pkg.vhd` | unchanged |
| `profile.txt` | 4 probes, one per slot |

## Schedule
Window w(i) = φ^(a-1+i), i = 0..6.

| Phase | A0 | A1 | B0 | B1 | Then |
|---|---|---|---|---|---|
| AD block 0 (N‖AD0) | tag ← block | | | | LFSR load (a = -5) + step 4, 2, 1 → a = 2 |
| AD batch j..j+3 (a = j+1) | A_j ⊕ w0 | A_{j+1} ⊕ w1 | A_{j+2} ⊕ w2 | A_{j+3} ⊕ w3 | tag ^= Σ (result ⊕ same mask); step 4. The next batch fills meanwhile |
| Message start (a = 1, after load + step 4 + step 2) | KS(0) | KS(1) | KS(2) | KS(3) | KS(0)/KS(1) → keystream buffers; B0/B1 unmask in place; blocks 0, 1 stream |
| Batch (k, k+1) full, more follows (a = k+1) | MAC(k) = C_k ⊕ w0⊕w2 | MAC(k+1) = C_{k+1} ⊕ w1⊕w3 | KS(k+4) = N ⊕ w4⊕w5 | KS(k+5) = N ⊕ w5⊕w6 | keystream buffers ← KS(k+2)/KS(k+3) from B0/B1 at setup; blocks k+2, k+3 stream meanwhile; tag ^= MACs; B0/B1 unmask; step 2 |
| Last batch | MAC(k) | MAC(k+1) if present | | | |
| Final | P(S ⊕ L) ⊕ L | | | | tag = low 64 bits of A0 |

If the message ends on a block boundary, the padding-only block now usually lands in the same batch as
the last data block, so its MAC runs in parallel (this was a follow-up item in r4_BtoC).

## Timing fix included
- `key_out` loads `pout(1)` (the permutation output that feeds A0) directly, not through the slot load mux.
- The loader sets a **registered** `batch_done`; the main FSM's load enables start from flip-flops, not from
  `data_cnt_int` compares. This costs one cycle per batch.

## Results (2026-11-19)
- Validation: `make sim-all CORE=brody/r4_BtoD` passes random 1000, edge 374, full33 2178, long 10,
  badtag 374, and `make cycles` checks all 81 of its vectors.
- `make profile WL=long`: 5274 (r4_BtoC) → **2916** cycles (−45%). All four slots are busy together in 79.6% of
  cycles; overlap (busy+io) is 46.9%.
- `make profile WL=short`: 246 → 252 cycles (+6): the registered `batch_done` adds a cycle per batch, and the
  LFSR setup in `AD_INIT` takes 4 cycles instead of 3.
- `make cycles`: per PT block 21.74 (r4_BtoC) → **10.87**, per AD block 11.19 → **6.50** (the loader floor is 6);
  1536 B PT 1759 → 931 cycles; 16 B PT 87 → 89.
- `make synth` (PERIOD0=5.5, closed at 6.787 ns after 4 runs): **147.8 MHz, 4732 LUT, 2403 FF**
  (r4_BtoC: 169.5 MHz, 2736 LUT, 1572 FF).
- `make report`, compared with r4_BtoC:
  - **Throughput:** 2175 Mbps long PT (×1.74; ×4.03 vs `brody/base`) and 3640 Mbps long AD (×1.50).
  - **Efficiency:** 459.7 Kbps/LUT for PT, about the same as r4_BtoC's 455.9. AD efficiency falls from 885.7 to 769.2.
  - **16 B PT:** 249 → 213 Mbps, from the lower Fmax and 2 more cycles.
- Critical path: `batch_done` → loader handshake (`bdi_ready`/`bdo_valid`) → the PostProcessor's FSM, 13 levels
  (including CARRY4), 66% routing. The timing fix moved the bottleneck off the 160-bit muxes. It is now the
  loader's control fanning into the frozen wrapper.

## Takeaways
- 4 calls in flight double long-message throughput but not throughput per LUT. Area grows about as fast as
  throughput once Fmax drops 13%.
- AD is now at the loader floor (6.5 cycles per block against a floor of 6), so more slots won't help AD.

## Possible follow-ups
- The loader branch is gated on `batch_done = '0'`, but `data_cnt_int < BLOCK_SIZE` already implies it.
  Dropping that term and pre-computing the per-buffer selects shortens the path into the PostProcessor.
- Remove the loader's decision cycle per block (floor 6 → 5 cycles per block).
- Parameterize units × stages × rounds per stage (see the discussion in `rtl/ACCELERATION.md`).
