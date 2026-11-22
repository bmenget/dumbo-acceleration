# core_v2_r2_optBCDEFGHI: optBCDEFGHI at 2 rounds per stage

The RTL of [core_v2_r4_optBCDEFGHI](../core_v2_r4_optBCDEFGHI/OPT_BCDEFGHI.md) (register slices on both
wrapper handshakes, keystream head with the accept as its last mux) with the configuration of
[core_v2_r2_optBCDEFGH](../core_v2_r2_optBCDEFGH/OPT_BCDEFGH_R2.md): `PERM_ROUNDS_PER_CYCLE = 2`,
`NUNIT = 2`, `NSTAGE = 8` (16 calls in flight), `NKS = 10`, `tag_infl` range 0..31.

At 2 rounds per stage, H's clock was set entirely by the wrapper → loader handshake (171.4 MHz, no better
than 4 rounds per stage). With that path registered, the shorter stages pay off.

## Results (2026-11-22)
- Validation: `make sim-all` passes random 1000, edge 374, full33 2178, long 10, badtag 374; `make cycles`
  checks all 81 vectors.
- `make cycles`: +0 to +2 cycles per message against core_v2_r2_optBCDEFGH; per PT block 4.94. 16 B PT
  150 → 152, 64 B PT 165 → 167, 1536 B PT 530 → 532 (each dependent call takes 40 cycles).
- `make profile WL=long`: 1783 cycles (r2 H: 1787).
- `make synth`: **201.4 MHz, 5852 LUT, 4933 FF** (r2 H: 171.4 MHz, 5786 LUT, 4766 FF; +17.5%). Closed at
  5.024 ns with 0.059 ns of slack; 4.728 ns missed by 0.057 ns.
- Throughput at 201.4 MHz: **6521 Mbps long PT**, 6426 Mbps long AD, **1114 Kbps/LUT** (the highest of our
  cores); 1536 B PT 4652 Mbps; 16 B PT 170 Mbps.
- Critical path at 5.024 ns: **inside the frozen wrapper**, PreProcessor FSM → PostProcessor FSM (10 levels
  including a carry chain). Next, at 4.728 ns: our loader, input slice → `kh` enable / `ib` (6 levels),
  0.03–0.06 ns short. Both are about 4.8–5.0 ns, so this is close to what the wrapper allows.

## Takeaways
- Best long-message throughput and efficiency of all our cores, at the wrapper's own clock limit.
- Not the best overall: against optBCDEFGHI (4 rounds per stage) it loses on 16 B (170 vs 254 Mbps),
  64 B (618 vs 873) and even 1536 B (4652 vs 4751), because every dependent call (key, first keystream,
  final) takes 40 cycles instead of 20. It wins only from a few KB up. Which one to call "the" result
  depends on the workload the report weights.
