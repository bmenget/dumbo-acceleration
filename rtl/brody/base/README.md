# Elephant v1 -> Dumbo v2 port (brody/base)

Only `elephant_datapath.vhd` and `CryptoCore.vhd` differ from `gmu/arch1_v1`
(`diff -r rtl/gmu/arch1_v1 rtl/brody/base`). The permutation, LFSR, wrapper and testbench are unchanged.

## Why the existing LFSR window is enough
The 176-bit LFSR register exposes a window (prev, cur, next) = (phi^(a-1), phi^a, phi^(a+1)) of the mask
sequence phi^i(L), and slides by one per step. The C model needs, for block index k:

| Job | v2 mask | Hardware window |
|---|---|---|
| keystream (enc block k) | phi^k + phi^(k+1) | a = k+1: **prev + cur** |
| ciphertext MAC (block k) | phi^k + phi^(k+2) | a = k+1: **prev + next** |
| AD MAC (block j >= 1)    | phi^j             | a = j+1: **prev** |

So no LFSR change and no extra mask register. Message processing starts one LFSR step later than in v1
(`MDATA_NPUB`, `data_cnt_int = 2` instead of 1). AD timing is unchanged from v1.

## Changes
`elephant_datapath.vhd`
- `lfsr_mux_sel` is 3 bits: `000` raw block, `001` prev, `010` prev+cur, `011` prev+next,
  `100` S+L (final input), `101` ms+L (final output).
- Tag accumulator `tag_out` is 160 bits (was 64).
- Tag output is read from `ms_reg` (low 64 bits) after the final step, not from the accumulator.
- L = P(K||0) is already kept in `key_out`, so the final step needs no new register.

`CryptoCore.vhd`
- First AD block (N||AD0) is **not permuted**: at the end of its load, the raw block initializes the tag
  (`tag_en` with select `000`), then control goes straight to `POST_PERM` (which still steps the LFSR and
  decides the next state). Tracked by `first_blk`; it also clears the data register for the keystream
  nonce, which `PERM` does for later blocks.
- `PRE_PERM`/`POST_PERM` select the v2 masks above.
- New final step after the last ciphertext MAC: `calling_state = TAG_S` runs
  `PRE_PERM` (ms <= S+L) -> `PERM` -> `POST_PERM` (ms <= ms+L) -> `TAG_S` (outputs / checks the tag).
  This is the +1 permutation of latency versus v1.

## Status
Passes all generated v2 sets (random, edge, full33, long, badtag). `PERM_ROUNDS_PER_CYCLE` is still the
upstream value (10).
