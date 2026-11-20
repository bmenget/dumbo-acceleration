# core_v2_r4_optBC: I/O overlap plus two permutation units

Options B and C from [../ACCELERATION.md](../ACCELERATION.md), on top of
[core_v2_r4_optB](../core_v2_r4_optB/OPT_B.md) (`PERM_ROUNDS_PER_CYCLE = 4`, 20 cycles per permutation).
Compare against `core_v2_r4_optB` for the effect of C, and against `core_v2_r4` for B and C together.

| File | vs `core_v2_r4_optB` |
|---|---|
| `CryptoCore.vhd` | AD pairs, unit B control (`b_active`, `perm_b_en`), message schedule MAC(k) ‖ KS(k+2) |
| `elephant_datapath.vhd` | second `elephant_perm` (`PERM_B`) and state register `msb_reg`; second AD block buffer `load_data_output2`; unit B `srcb xor maskb` mux; tag takes both units' results; `ks_reg` can load from `msb_reg` |
| `elephant_datapath_lfsr.vhd` | window widened from 176 to 184 bits (+8 FF): a fourth mask, next2 = φ^(a+2). Taps move from offset 16 to 24 |
| `elephant_perm.vhd`, `elephant_constants.vhd`, `design_pkg.vhd` | unchanged |
| `profile.txt` | two probes: `perm_a` (`perm_en`) and `perm_b` (`perm_b_en`) |

The two units run in lockstep: one `perm_count`, same round constants. Unit B only updates `msb_reg` when
`b_active` is set.

## Schedule
Mask window at position a: prev = φ^(a-1), cur = φ^a, next = φ^(a+1), next2 = φ^(a+2).

| Phase | Unit A | Unit B | Overlapped with |
|---|---|---|---|
| AD block 0 (N‖AD0) | none; tag ← block | | LFSR load + 2 steps (a = 0) |
| AD pair (j, j+1), set up at a = j-1 | P(A_j ⊕ next) | P(A_{j+1} ⊕ next2) | filling pair (j+2, j+3) |
| | the LFSR steps once **during** the permutation (a = j); tag ^= (A ⊕ cur) ⊕ (B ⊕ next); step (a = j+1) | | |
| Message start (a = 0) | KS(0) = P(N ⊕ cur ⊕ next) → `ks_reg` | KS(1) = P(N ⊕ next ⊕ next2), kept in `msb_reg` | none |
| Block k full, more data (a = k+1) | MAC(k) = P(C_k ⊕ prev ⊕ next) | KS(k+2) = P(N ⊕ next ⊕ next2) | **streaming block k+1** from `ks_reg` ← KS(k+1) |
| | tag ^= MAC result; unit B unmasks KS(k+2) in `msb_reg`; step | | |
| Last block | MAC(k) (+ padding-only MAC block if the message ended on a block boundary) | idle | |
| Final | P(S ⊕ L) ⊕ L | idle | |

Why the extra mask: running MAC(k) together with KS(k+2) (not KS(k+1)) keeps option B's overlap. The
keystream for the block being streamed was computed one round earlier. That pairing needs φ^k, φ^(k+2) and
φ^(k+3) at once, which is one mask more than `core_v2`'s window. The mid-permutation step for AD pairs
lets the window advance two positions per pair while the POST cycle still unmasks from in-window masks.

## Results (2026-11-19)
- Validation: `make sim-all CORE=v2_r4_optBC` passes random 1000, edge 374, full33 2178, long 10,
  badtag 374, and `make cycles` checks all 81 of its vectors.
- `make profile WL=long`: 10126 → 5274 cycles vs `core_v2_r4_optB` (−48%), and 12260 → 5274 vs `core_v2_r4`
  (−57%). Both units are busy at once in 87.2% of cycles. Overlap (busy+io) is 28.5%, and I/O-only is 0.9%.
- `make profile WL=short`: 246 cycles, the same as optB. A 16 B AD + 16 B message has one permuted AD block
  and one message block, so there is never a second block for unit B to run alongside.

- `make cycles`: per PT block 42.81 (optB) → **21.74**; per AD block 22.06 → **11.19**; 1536 B PT 3355 → 1759 cycles.
  16 B PT is unchanged (87 cycles).
- `make synth` (PERIOD0=5.5, closed at 5.91 ns after 5 runs): **169.5 MHz, 2736 LUT, 1572 FF**
  (optB: 184.3 MHz, 1882 LUT, 1243 FF). That's +854 LUT (mostly the second permutation) and +329 FF (`msb_reg`,
  the second block buffer, 8 LFSR bits).
- `make report`, compared with optB:
  - **Throughput:** 1247 Mbps long PT (×1.81) and 2423 Mbps long AD (×1.81).
  - **Efficiency:** 455.9 Kbps/LUT for PT (+25%).
  - **16 B PT:** 249 Mbps, down from 271. The cycles are the same, but Fmax is lower.
- Critical path: `data_cnt_int` → `blk_full`/`ad_ready` → `src`/`mask` selects → `key_out_reg`, 5 LUT levels with
  84% of the delay in routing. It's control fanout into the 160-bit muxes, not the permutation. optB's path was
  also control (`ctl_s` → `ms_reg`), at 5.3 ns.

## Not done (possible follow-ups)
- **Fmax:** `key_out` only ever loads the key permutation's output, but its D input goes through
  `ms_reg_input_mux`. Wiring it to `permout` directly takes it off the critical path. After that, register
  `blk_full`/`ad_ready` (or the mux selects) one cycle early, so control decisions don't fan straight into
  160-bit muxes.
- The padding-only MAC block (message length a multiple of 20 B) runs after MAC(k), not alongside it. Its
  mask φ^(k+1) ⊕ φ^(k+3) is cur ⊕ next2 in the same window, so unit B could take it.
- The last AD pair and the message start are serial. They share the mask LFSR, so overlapping them would
  need a second LFSR.
- KS(0) ‖ KS(1) is wasted work for an empty message (as in `core_v2`, which computes KS(0)).
