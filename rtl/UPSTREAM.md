# Upstream provenance: rtl/

| Path | Source | Commit |
|---|---|---|
| `shared/lwc/*.vhd` | https://github.com/GMUCERG/Elephant `src_rtl/v1/LWC/` | `090d1e745fa28add5d11634cec9883681e6bc763` |
| `gmu/arch1_v1/*.vhd` | same repo, `src_rtl/v1/*.vhd` (GMU arch-1) | same |
| `brody/base/*.vhd` | started as a copy of `gmu/arch1_v1/`; **modified** for Dumbo v2 (`elephant_datapath.vhd`, `CryptoCore.vhd`); other files identical to upstream | same |
| `logan/src/*.sv` | https://github.com/ljtalton/dumbo-fpga (Logan's SystemVerilog cores), unmodified; details in `logan/src/UPSTREAM.md` | `74a0ef47b5db14b6f6eaf92861b61e981c8fbb52` |

`shared/lwc/` and `gmu/arch1_v1/` are byte-identical to upstream. Do not edit them.
`diff -r gmu/arch1_v1 brody/base` shows exactly what the v2 port changed.
`gmu/arch1_v1/elephant_constants.vhd` keeps upstream `PERM_ROUNDS_PER_CYCLE := 10`
(GMU's docs describe arch-1 as 1 round/cycle; set it to 1 only for benchmarking).

License: GNU GPL v3, as stated in the file headers. The upstream repo has no
LICENSE file of its own; see https://www.gnu.org/licenses/gpl-3.0.txt.
`filelist.txt` in each core folder is ours (compile order from upstream `source_list.txt`).
