# brody/base_r1: reference point, not an optimization

`brody/base` with `PERM_ROUNDS_PER_CYCLE = 1` (80 cycles per permutation). That is the only difference
(`diff -r rtl/brody/base rtl/brody/base_r1`).

Purpose: compare our flow with `Elephant_GMU` in GMU's LWC benchmark (Mohajerani et al., ePrint 2023/484,
`docs/SCA-Benchmarking.pdf`, Tables 12 and 14): 222 MHz, 1,375 LUTs, 912 FFs, 208 Mbps long plaintext,
151 Kbps/LUT on xc7a100tftg256-2L. Its throughput implies about 171 cycles per plaintext block, which is
this architecture at one round per cycle.

Expected differences: `Elephant_GMU` may be spec v1 (64-bit tag accumulator vs our 160-bit, so fewer FFs),
and GMU's Xeda flow also searches synthesis strategies (possibly higher Fmax).

## Result (2026-11-19, xc7a100tftg256-2L, Vivado 2026.1)
| | brody/base_r1 | Elephant_GMU (paper) |
|---|---|---|
| Cycles per plaintext block | 170.2 (measured) | about 171 (implied by 208 Mbps at 222 MHz) |
| Fmax | 168.3 MHz | 222 MHz |
| LUTs / FFs | 1,534 / 1,089 | 1,375 / 912 |
| Plaintext long / 1536 / 64 / 16 B | 158.2 / 155.9 / 110.2 / 80.1 Mbps | 208 / 204 / 131 / 80 Mbps |
| Kbps/LUT (plaintext) | 103.1 | 151 |

- Cycles per block match: same serial architecture at one round per cycle.
- Area within about 12% (LUTs); more FFs, consistent with the larger v2 tag accumulator.
- Fmax 24% lower. Our search met the first target (6.0 ns) with +0.057 ns slack, so it was not pushed
  tighter; GMU's Xeda flow also searches synthesis strategies.
- 16 B messages: ours takes about 269 cycles, theirs implies about 355. Cause not established.
