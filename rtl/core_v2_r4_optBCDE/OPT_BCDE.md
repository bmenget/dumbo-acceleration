# core_v2_r4_optBCDE: staggered permutation calls

Option E on top of [core_v2_r4_optBCD](../core_v2_r4_optBCD/OPT_BCD.md): same hardware shape (two units,
each an 8-round loop cut into two 4-round stages, so 4 calls in flight), but the calls no longer move in
lockstep. Each call starts as soon as its input is ready and finishes 20 cycles later, independently of
the others. Compare against `core_v2_r4_optBCD`. [core_v2_r4_optBCDEF](../core_v2_r4_optBCDEF/OPT_BCDEF.md)
adds the fast loader on top.

## Lockstep vs staggered
optBCD loads a batch of up to 4 calls together, runs them together for 20 cycles, and unloads them
together. So a batch waits for its last block, every batch pays setup and unmask cycles, and the tag XORs
4 results at once.

optBCDE treats each stage register as carrying its own call:
- **Per-register round counter:** `pc(p)` moves through the ring with the call and indexes that stage's
  round-constant ROM, so the two stages of a ring can be at different rounds.
- **One new call per cycle:** an issue engine, one cycle ahead, picks a register whose call will be gone
  next cycle (empty or finishing), and the oldest request:
  KEY > FIN > next full input buffer (AD or MAC, in block order) > a keystream call.
- **One result per cycle:** a finished call's stage output and mask are registered. The next cycle the
  unmasked result goes to the key, the tag (one XOR) or the keystream FIFO.
- **Keystream runs ahead:** keystream calls need only the nonce and L, so they start during AD and stay up
  to `NKS` = 3 blocks ahead of the message (a FIFO of 3 keystreams). Message words stream out as soon as
  they arrive, as before.
- **Two input buffers:** a block is called as soon as it is complete; the loader fills the other buffer
  meanwhile.

## Files (vs core_v2_r4_optBCD)
| File | Change |
|---|---|
| `elephant_datapath.vhd` | rewritten: one shared x = src ⊕ mask (one load per cycle) instead of four slot muxes; per-register round index; mask store (4 × 160 FF); result + mask registers; 2 input buffers; 3-deep keystream FIFO; tag takes one result per cycle |
| `elephant_datapath_lfsr.vhd` | new entity `elephant_mask_lfsr` (generic window size, load + single step). Two instances: AD/MAC window (3 masks) and keystream window (2 masks), so keystream and MAC can be at different block indices |
| `elephant_constants.vhd` | `NSLOT`, `NKS`, `SEG_WAIT`, mask window sizes, call kinds `K_*`, `pc_arr` |
| `CryptoCore.vhd` | rewritten: main FSM (key, nonce, RUN, tag), loader with two buffers, issue engine tracking each register's call |
| `elephant_perm.vhd`, `design_pkg.vhd` | unchanged (each stage now gets its own `perm_count`) |
| `profile.txt` | one probe per stage register (`busy` = holds a live call) |

## Masks
| Call | Mask | Window |
|---|---|---|
| AD block j (j ≥ 1) | φ^j | MAC window w0; load + 3 steps → φ^1, one step per call |
| MAC(k) | φ^k ⊕ φ^(k+2) | MAC window w0 ⊕ w2; reloaded + 2 steps → φ^0, one step per call |
| KS(k) | φ^k ⊕ φ^(k+1) | KS window w0 ⊕ w1; load + 1 step → φ^0, one step per call |
| Final | L | `key_out` |

## Segment detection
The lockstep cores decide "no AD" / "no message" from `bdi_type` at a fixed point that happened to be
late enough. optBCDE gets to the first AD and message block much sooner, so the first block of each
segment now waits until `bdi_type` shows the segment (AD, or PT/CT). Any other type, or `SEG_WAIT` = 16
cycles of `"0000"` (the PreProcessor reading a header), means the segment is empty.

## Results (2026-11-20)
- Validation: `make sim-all` passes random 1000, edge 374, full33 2178, long 10, badtag 374; `make cycles`
  checks all 81 vectors.
- `make cycles`: per PT block 10.87 (optBCD) → **9.88**, per AD block 6.50 → **6.02** (the loader floor
  of 6 with its decision cycle); 1536 B PT 931 → **848**; 16 B PT 89 → 88; 64 B PT 117 → 118.
- `make profile WL=long`: 2916 (optBCD) → **2616** cycles (−10%). All four registers hold a call 70.1% of
  the time (optBCD: 79.6% busy together, but in batches with idle gaps); idle cycles 9.4% → 0.9%.
- `make synth` (closed at 6.165 ns after 2 runs): **163.8 MHz, 5639 LUT, 3421 FF** (optBCD: 147.8 MHz,
  4732 LUT, 2403 FF). +19% LUT for the mask store, keystream FIFO, result registers and per-register round
  constants; the four slot muxes collapse into one shared x.
- Throughput at 163.8 MHz: **2653 Mbps** long PT (×1.22 vs optBCD), about 4350 Mbps long AD (×1.20),
  **470 Kbps/LUT** (optBCD 460); 16 B PT 213 → 238 Mbps.
- Critical path: three-way tie within 1.4%:
  - `perm`: stage register → 4 rounds → the 4:1 result mux into `res` (6 levels, 83% routing). That mux is
    the price of taking a finished call straight from the stage output.
  - `core->wrapper`: keystream FIFO head → `bdo` → PostProcessor FSM (frozen wrapper).
  - `ctrl->datapath`: registered issue (`iss_p`, `iss_kind`) → shared x → stage register.
  The batch_done → loader handshake path that limited optBCD is gone.

## Takeaways
- Plaintext is now bound by the slots: 2 calls per block × 20 cycles / 4 slots = 10 cycles per block.
  The remaining gain has to come from more slots or a faster clock, not from scheduling.
- AD is bound by the loader (6 cycles per block); the fast loader (optBCDEF) removes that cycle.
