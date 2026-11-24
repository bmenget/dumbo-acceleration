# Logan's Dumbo v2 cores (SystemVerilog)

Shared sources for Logan's cores (`rtl/logan/*/`) and the merged cores built on them (`rtl/merged/pipe*/`), the same way `rtl/shared/lwc/` is shared by every core.

| File | Source | Commit |
|---|---|---|
| `spongent_round.sv`, `spongent_perm_ws.sv`, `CryptoCore.sv`, `spongent_perm_pipe.sv`, `CryptoCorePipe.sv` | https://github.com/ljtalton/dumbo-fpga `rtl/` | `74a0ef47b5db14b6f6eaf92861b61e981c8fbb52` |
| `CryptoCore_pipe_shim.sv` | same repo, `lwc/` | same |
| `design_pkg.vhd` (in `rtl/logan/glue/`) | **ours** (his `lwc/design_pkg.vhd` lacks `CCWdiv8`, which our older wrapper needs) | |

The `.sv` files are byte-identical to upstream. Do not edit them; a modified Logan core gets its own copy.

## Two cores, one module name
Both define a module `CryptoCore` (the name our wrapper instantiates, without generics), so a filelist
includes exactly one of them:
- **Iterative**: `CryptoCore.sv` (+ `spongent_round.sv`, `spongent_perm_ws.sv`). Word-serial, one permutation,
  `R` rounds per cycle from the define `DUMBO_R`. 2 * (5 + 80/R) cycles per 20-byte block.
- **Pipelined ring**: `CryptoCore_pipe_shim.sv` (module `CryptoCore`) wrapping `CryptoCorePipe.sv`
  (+ `spongent_round.sv`, `spongent_perm_pipe.sv`). `S` ring stages (calls in flight) of `K` rounds each,
  keystream FIFO depth `D`, from the defines `DUMBO_S`, `DUMBO_K`, `DUMBO_D` (S*K must divide 80).

The sizes come from Verilog defines because the wrapper's VHDL component has no generics. Each core directory
sets them in `defines.txt` (one `NAME=VALUE` per line); `make sim` passes them to `vlog` as `+define+`, and
`make synth` to `synth_design` as `-verilog_define`.

## Configurations
| Core | Defines | Logan's own result (newer wrapper, Vivado 2024.1, his Fmax search) |
|---|---|---|
| `logan/r4` | `DUMBO_R=4` | iterative, 50 cycles/block |
| `logan/pipe20x2d16` | `DUMBO_S=20 DUMBO_K=2 DUMBO_D=16` | 218.6 MHz, 5,586 LUT, 7.0 Gbps |
| `logan/pipe10x2d8` | `DUMBO_S=10 DUMBO_K=2 DUMBO_D=8` | 230.4 MHz, 3,750 LUT, 4.61 Gbps |
| `logan/pipe16x1d16` | `DUMBO_S=16 DUMBO_K=1 DUMBO_D=16` | 3.43 Gbps |

Modified configurations (our additions; `rtl/logan/src/` itself stays unchanged):

| Core | Change | Result in our flow |
|---|---|---|
| `merged/pipe20x2d16_I` | our option I: register slices on `bdi` / `bdo` (`CryptoCore_slice_shim.sv`), see its `README.md` | 245.2 MHz (base 222.5), 5607 LUT, 7892 Mbps, 1408 Kbps/LUT |
| `merged/pipe20x2d16_IL` | pipe20x2d16_I + a key slice + our option L in a modified copy of `CryptoCorePipe.sv` (KB / TI data selects from registers), see its `README.md` | 249.2 MHz, 5700 LUT, 8021 Mbps, 1407 Kbps/LUT |
| `merged/pipe16x2d16_ILN` | pipe20x2d16_IL + our option N: a **32-round ring with two entry/exit points** (modified copy of `spongent_perm_pipe.sv`, parameter P), see its `README.md` | 247.1 MHz, 5176 LUT, 8000 Mbps, **1546 Kbps/LUT** |
| `merged/pipe10x2d8_IL` | the pipe20x2d16_IL shim and core copy at S=10, K=2, D=8, see its `README.md` | 244.1 MHz (base 215.4), 3865 LUT, 4807 Mbps, 1244 Kbps/LUT |

His numbers are not comparable with ours (different wrapper version, Vivado version and Fmax search); run
our flow for numbers that are.

## Profile probes
- Iterative: `u_perm/busy` ('1' while the permutation computes rounds).
- Ring: `u_core/u_ring/vl[s]` for each stage s (the shim's instance is `u_core`): stage s holds a call in flight,
  so it computes rounds that cycle.
