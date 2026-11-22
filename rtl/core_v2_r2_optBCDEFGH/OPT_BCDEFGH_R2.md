# core_v2_r2_optBCDEFGH: H at 2 rounds per stage (negative result)

The RTL of [core_v2_r4_optBCDEFGH](../core_v2_r4_optBCDEFGH/OPT_BCDEFGH.md) with half the rounds per stage
register and twice the stages, so the total stays at 32 rounds per cycle, the 32-bit bus limit. The
question was whether shorter stages would let the clock pass optBCDEFGH's 174.6 MHz. They don't: the
wrapper handshake sets the clock in both designs.

## Configuration (`elephant_constants.vhd`)
- `PERM_ROUNDS_PER_CYCLE = 2` (40 cycles per call), `NUNIT = 2`, `NSTAGE = 8`: 16 stage registers,
  16 calls in flight.
- `NKS = 10`: a keystream call now takes about twice as long from issue to result, so more must be issued
  ahead. Measured at 1536 B PT: NKS 8 gives 6.23 cycles per block, NKS 10 gives 4.93. NKS 12 matches 10
  on plaintext but is slightly worse on mixed AD + PT (883 vs 873 cycles), because keystream calls then
  take slots that AD calls could use.
- `tag_infl` range 0..31 in `CryptoCore.vhd` (up to 16 calls in flight).
- `profile.txt`: 16 probes, one per stage register.

## Results (2026-11-20)
- Validation: `make sim-all` passes random 1000, edge 374, full33 2178, long 10, badtag 374; `make cycles`
  checks all 81 vectors.
- `make cycles`: per PT block **4.94**, per AD block 5.01 (same as optBCDEFGH); 1536 B PT 530 (H: 470);
  64 B PT 165 (H: 105); 16 B PT 150 (H: 90). Every call in a dependent chain (key, first keystream,
  final) takes 40 cycles instead of 20, so short messages pay about 60 cycles more.
- `make profile WL=long`: 1787 cycles (H: 1687).
- `make synth`: **171.4 MHz, 5786 LUT, 4766 FF**, closed at 6.0 ns. A first build, before the keystream
  FIFO change shared with H, closed at 176.4 MHz with 5813 LUT; the 5.747 ns probe after the change
  missed by 0.28 ns.
- Area vs optBCDEFGH (`cells.tsv`): rounds 5120 LUT (5040); stage registers 2560 FF (1280); mask delay
  line 320 SRL (160); round constants 128 FF (80). The rest is the same.
- Throughput at 171.4 MHz: 5549 Mbps long PT, 5469 Mbps long AD, 959 Kbps/LUT; 1536 B PT 3974 Mbps;
  16 B PT 146 Mbps.
- Critical path: the wrapper's PreProcessor FSM → loader → `dp/kh` (7 levels, 79% routing), the same
  path that limits optBCDEFGH. The 2-round stages are nowhere near critical.

## Takeaways
- Worse than optBCDEFGH on every metric: about the same clock, +290 LUT, +1396 FF, and 60 extra cycles per
  short message. Kept as a data point.
- Some sweep points at 1–2 rounds per stage reach 210–230 MHz, but those are the generic lockstep cores
  with a different loader. In this design the staggered loader's handshake logic, not the rounds, holds
  the clock near 175 MHz, so shortening the stages buys nothing.
- *Update:* with the handshake registered, [core_v2_r2_optBCDEFGHI](../core_v2_r2_optBCDEFGHI/OPT_BCDEFGHI_R2.md)
  reaches 201.4 MHz at 2 rounds per stage.
