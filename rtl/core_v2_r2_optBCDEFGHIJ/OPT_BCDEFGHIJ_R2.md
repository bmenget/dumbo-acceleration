# core_v2_r2_optBCDEFGHIJ: optBCDEFGHIJ at 2 rounds per stage

The RTL of [core_v2_r4_optBCDEFGHIJ](../core_v2_r4_optBCDEFGHIJ/OPT_BCDEFGHIJ.md) (option J: source and
mask select on registered 2-bit codes) with the configuration of
[core_v2_r2_optBCDEFGHI](../core_v2_r2_optBCDEFGHI/OPT_BCDEFGHI_R2.md): 2 rounds per stage, 2 × 8 stages,
`NKS = 10`, `tag_infl` range 0..31.

## Results (2026-11-22)
- Validation: `make sim-all` passes random 1000, edge 374, full33 2178, long 10, badtag 374; `make cycles`
  checks all 81 vectors (16 B PT 152, 1536 B PT 532, as r2 I). `make profile WL=long`: 1783.
- `make synth`: **197.6 MHz, 5767 LUT, 4928 FF** (r2 I: 201.4 MHz, 5852 LUT, 4933 FF). Two searches:
  - from 5.024 ns: missed by 0.035 ns, closed at 5.312 ns (190.1 MHz, 5784 LUT);
  - from 5.060 ns: met with 0.000 ns slack (197.6 MHz), then 4.739 ns missed by 0.084 ns (211.0 MHz achieved)
    and 4.976 ns missed by 0.041 ns. The result is the second search (`make report` uses the latest).
- Throughput at 197.6 MHz: 6398 Mbps long PT, **1109 Kbps/LUT** (r2 I: 1114); 16 B PT 166 Mbps.

## Takeaways
- J saves 85 LUTs here, as at 4 rounds per stage. The clock is set by the frozen wrapper's own paths
  (see r2 I), which J doesn't touch; the 2% lower Fmax is the spread between Vivado searches (a failed run of
  the same search reached 211 MHz), so r2 I and r2 J tie on throughput per LUT.
