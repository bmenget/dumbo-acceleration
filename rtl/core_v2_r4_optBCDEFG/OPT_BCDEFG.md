# core_v2_r4_optBCDEFG: more slots, shorter critical paths

Option G on top of [core_v2_r4_optBCDEF](../core_v2_r4_optBCDEF/OPT_BCDEF.md). optBCDEF was slot-bound on
plaintext: 2 calls per block × 20 cycles / 4 slots = 10 cycles per block. G doubles the round hardware
(4 units × 2 stages × 4 rounds = 8 calls in flight), which brings plaintext to the 32-bit bus limit of 5
cycles per block. It also shortens the three paths that tied as optBCDEF's critical path, so the wider
design keeps its clock.
[core_v2_r4_optBCDEFGH](../core_v2_r4_optBCDEFGH/OPT_BCDEFGH.md) keeps these cycles with 25% fewer LUTs.

## Configuration
The ring geometry is generic now: `NUNIT` rings of `NSTAGE` stage registers, `PERM_ROUNDS_PER_CYCLE`
rounds per stage (any divisor of 80 of at least 2), in `elephant_constants.vhd`. A call moves from
register p to `nxt(p)` each cycle. `vslot(p, ph)` gives its mask store entry, which stays the same while
the call runs. Built and measured here: `NUNIT = 4`, `NSTAGE = 2`, 4 rounds per stage, `NKS = 6`.

Plaintext cycles per block with staggered calls are about 2 × 80 / (rounds per cycle over all units)
= 160 / (NUNIT × NSTAGE × rounds per stage) = 160 / 32 = 5, the bus limit.

## What changes (vs core_v2_r4_optBCDEF)
- **More slots:** 8 stage registers instead of 4. The issue engine, the mask store and the result
  capture are written for any `NSLOT`.
- **Keystream FIFO depth `NKS` = 3 → 6:** at 5 cycles per block a keystream call is issued about 6
  blocks before its block is done (issue-to-result latency plus the block itself). Measured at 1536 B PT:
  NKS 3: 9.9, 4: 7.5, 5: 5.9, 6: 4.9 cycles per block.
- **Issue two cycles ahead (load path):** a decision in cycle t prepares `x = src ⊕ mask` in t+1 (stage
  A) and registers it with its mask (`xr`, `mr`); in t+2 (stage B) `xr` goes into the chosen stage
  register and `mr` into the mask store. The mux in front of each stage register is now only `xr` /
  ring, and the wide source and mask muxes end in a register. The free-register test looks two
  cycles ahead: the call that would reach the register then must be gone or in its last round group,
  and neither the stage-A nor the stage-B call may be headed there.
- **Registered round constants (perm path):** each stage register's round constants (`rc`, one byte
  per round) are registered next to its round counter, from a table `RC_TAB` generated in the
  constants package. `elephant_perm` takes `rc` instead of a round counter, so a stage's path starts at
  the state register, not at a counter and a ROM.
- **Binary result index (perm path):** the finishing register and its mask entry go to the datapath as
  integers (`res_i`, `res_mi`), so the result capture is one N:1 mux (LUT6 + MUXF7) instead of a
  one-hot AND-OR.
- **Keystream head shifts per word (wrapper path):** the FIFO head `kh` moves one word right whenever a
  message word goes out (`ks_adv`), so the outgoing keystream word is always `kh(31:0)`. The 5:1
  `data_count` mux in front of `bdo` is gone. The rest of the FIFO is a circular store of `NKS-1`
  entries (enable only, no per-entry shift mux).
- `profile.txt`: one probe per stage register (`g_busy(p)/busy`).

Cost of the extra issue stage: each call's result arrives one cycle later, so dependent chains (key,
first keystream, final) are slower by a cycle or two; short messages pay 2–3 cycles.

## Results (2026-11-20)
- Validation: `make sim-all` passes random 1000, edge 374, full33 2178, long 10, badtag 374; `make cycles`
  checks all 81 vectors.
- `make cycles`: per PT block 9.86 (optBCDEF) → **4.93**, the bus limit; per AD block stays 5.00.
  1536 B PT 847 → **470**; 1536 B AD 473 → 470; 160 B PT 167 → 130; 64 B PT 116 → 105; 16 B PT 87 → 90.
- `make profile WL=long`: 2476 (optBCDEF) → **1687** cycles (−32%). The run is now I/O-bound: a word moves
  in 92% of the cycles. All 8 registers hold a call 44.9% of the time; rings c and d are used about
  half as much as a and b, because the issue engine takes the lowest free register.
- `make synth`: **161.2 MHz, 7295 LUT, 4841 FF** (optBCDEF: 162.4 MHz, 5631 LUT, 3430 FF). Closed at
  6.266 ns, reproduced by a second search started there (`PERIOD0=6.266`); a search started at 6.0 ns
  missed 6.0 and 6.337 ns by 0.014 and 0.022 ns and fell back to 6.971 ns, which is Vivado noise. LUT
  count depends on the target period (6183 at 6.97 ns, 8312 at 6.0 ns): tighter targets replicate logic.
  +1664 LUT (+30%) for 4 more 4-round stages, 4 more mask store entries, 3 more keystream entries.
- Throughput at 161.2 MHz: **5219 Mbps long PT** (×1.99 vs optBCDEF), 5143 Mbps long AD (same as
  optBCDEF: bus-bound), **715 Kbps/LUT** (optBCDEF 467, ×1.53); 1536 B PT 4215 Mbps; 16 B PT 229 Mbps
  (optBCDEF 239: the extra issue stage). The sweep's best lockstep point, r4s1u8, reaches 4186 Mbps long PT.
- Critical path: still a stage register (`rc` or `r`) → 4 rounds (5 LUT levels) → the 8:1 result mux
  (LUT6 + MUXF7) into `res`, 76% routing. The other two optBCDEF paths are gone: issue → `xr` has 0.45 ns
  of slack, and keystream → `bdo` no longer appears. In the failed 5.667 ns run the next paths were the
  ring itself (`r` → 4 rounds → `r`, −0.17 ns) and the frozen wrapper's own FSMs (−0.18 ns). So moving
  the result mux off the path would gain about 0.13 ns (2%), at the cost of a cycle of result latency
  and 640 FF; not done.

## Takeaways
- Plaintext and AD are both at the 32-bit bus limit now (about 5 cycles per 20 B block). More round
  hardware would not help long messages, only a wider bus would.
- The clock is set by 4 rounds per stage plus routing (about 170 MHz floor, shared with the frozen
  wrapper). Fewer rounds per stage would need more stages and slots for the same cycles per block, and
  the wrapper caps the gain.
- What's left is short-message latency (16 B: 90 cycles, mostly the chain of key, keystream and final
  calls at 20+ cycles each) and area.
