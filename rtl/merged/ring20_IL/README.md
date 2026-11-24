# merged/ring20_IL: Logan's 10×2 ring with our options I and L

The same shim (`CryptoCore_slice_shim.sv`: register slices on bdi, bdo and key) and modified core copy
(`CryptoCorePipe.sv`: KB / TI data selects from registers) as
[merged/ring40_IL](../ring40_IL/README.md), with `DUMBO_S=10 DUMBO_K=2
DUMBO_D=8`. Compared against [logan/ring20](../../logan/ring20/).

## Results (2026-11-23)
- Validation: `make sim-all` passes random 1000, edge 374, full33 2178, long 10, badtag 374; `make cycles`
  checks all 81 vectors; cycles per long PT block 8.12 (as the base: 20 rounds, 160/20 = 8).
- `make synth`: **244.1 MHz, 3865 LUT, 3853 FF** (base: 215.4 MHz, 3666 LUT, 3607 FF). The search was split
  in two by a restart (SSH disconnect): 4.117 failed by 0.005 (242.6 MHz achieved); resumed: 4.328 met
  (+0.232, 244.1 MHz achieved), 3.768 failed by 0.293 (246.2 MHz achieved), 4.264 met (241.0 MHz achieved).
- Throughput at 244.1 MHz: **4807 Mbps long PT (+13.3%)**, **1244 Kbps/LUT (+7.5%)**; 16 B PT 217 Mbps.

## Takeaways
- I + L give the 10×2 ring the same +11–13% clock as the 20×2 (both now about 244–249 MHz): the control logic,
  not the ring size, set their clock. +199 LUT (+5.4%) for the slices and the L changes.
- A mid-size point: 4.8 Gbps in 3.9 k LUT.
