# core_v2_r4_optB: I/O overlapped with the permutation

Option B from [../ACCELERATION.md](../ACCELERATION.md), on top of `core_v2_r4` (`PERM_ROUNDS_PER_CYCLE = 4`,
20 cycles per permutation). Compare against `core_v2_r4`. The only change between the two is the overlap.

| File | vs `core_v2_r4` |
|---|---|
| `CryptoCore.vhd` | rewritten FSM: a block filler (loader) running alongside a permutation scheduler |
| `elephant_datapath.vhd` | `src xor mask` input mux, `ks_reg` keystream buffer, nonce read straight from `npub_out` |
| `elephant_perm.vhd`, `elephant_datapath_lfsr.vhd`, `elephant_constants.vhd`, `design_pkg.vhd` | unchanged |

## Schedule
Mask window at position a: prev = φ^(a-1), cur = φ^a, next = φ^(a+1). It steps once per AD block and once per
ciphertext MAC block.

| Phase | Permutation | Overlapped with |
|---|---|---|
| AD block 0 (N‖AD0) | none; tag ← block | LFSR load + 3 steps (a = 2) |
| AD block j ≥ 1 | P(A_j ⊕ prev), tag ^= result ⊕ prev, step | filling AD block j+1 |
| Message start | LFSR reload + 1 step (a = 0); KS(0) = P(N ⊕ cur ⊕ next) → `ks_reg`; step | none |
| Message block k filled, no eot yet (a = k+1) | KS(k+1) = P(N ⊕ cur ⊕ next) → `ks_reg` | none (block k+1 needs it) |
| | MAC(k) = P(C_k ⊕ prev ⊕ next), tag ^= result ⊕ prev ⊕ next, step | **streaming block k+1** from `ks_reg` |
| Last block filled | MAC(k); if the message ended on a block boundary, the 0x01 padding block fills meanwhile and gets one more MAC | |
| Final | P(S ⊕ L) ⊕ L → `ms_reg`, tag = low 64 bits | |

The key point is that KS(k+1) and MAC(k) use the **same** window (cur⊕next and prev⊕next at a = k+1), so the
LFSR is unchanged. The loader writes the next block into `load_data_output` while `ms_reg` permutes, because
MAC(k) captures `C_k ⊕ masks` into `ms_reg` in one cycle (`SRC_BLK`) before the loader restarts. The
keystream nonce comes from `npub_out` (`SRC_NONCE`), so it no longer passes through `load_data_output`.

## Behavior kept from core_v2
- AD block 0 decides "no AD" from `bdi_type /= HDR_AD`, and the first keystream permutation decides
  "empty message" from `bdi_type` not being PT/CT. These are the same checks at about the same time as
  `core_v2`.
- AD blocks after the first now end **only** on the eot flags, not on `bdi_type`, so a header cycle between
  AD segments can't end the AD early. This is more robust than `core_v2`, not less.
- An empty message still computes KS(0) and throws it away, as `core_v2` does.

## Results (2026-11-19)
- Validation: `make sim-all CORE=v2_r4_optB` passes random 1000, edge 374, full33 2178, long 10, badtag 374.
- `make profile WL=long`: 12260 → 10126 cycles vs `core_v2_r4` (−17.4%). The permutation is busy 75.9% → 91.8%;
  I/O-only cycles drop from 12.6% to 0.3%.
- `make profile WL=short`: 252 → 246 cycles. Short messages have no next block to overlap.
- `make cycles`: 50.74 → 42.81 cycles per PT block (−15.6%), 28.08 → 22.06 per AD block (−21.4%),
  3965 → 3355 cycles for 1536 B of PT.
- `make synth` (PERIOD0=5.5): 184.3 MHz, 1882 LUT, 1243 FF (+158 FF, mostly `ks_reg`). At 6.0 ns it met timing
  at 167.2 MHz with 1800 LUT. `core_v2_r4`'s 166.3 MHz row is flagged `not_closed` and was never re-run tighter,
  so the Fmax gap between the two is mostly the synthesis flow, not the design. Compare cycles for the effect of B.
- Stall mode (`TESTMODE=1`) was not usable as a check: GMU's unmodified `core_v1` doesn't finish the edge
  set under it either.

## Not done (possible follow-ups)
- Each permutation still has a separate POST cycle (tag update or `ks_reg` load) and a setup cycle. Giving the
  tag its own XOR path would let POST merge with the next setup (about 1 cycle per permutation).
- KS(k+1) itself has nothing to overlap with on one unit. That's what options C/D are for.
