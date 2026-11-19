# Upstream provenance: rtl/

| Path | Source | Commit |
|---|---|---|
| `lwc/*.vhd` | https://github.com/GMUCERG/Elephant `src_rtl/v1/LWC/` | `090d1e745fa28add5d11634cec9883681e6bc763` |
| `core_v1/*.vhd` | same repo, `src_rtl/v1/*.vhd` (GMU arch-1) | same |
| `core_v2/*.vhd` | started as a copy of `core_v1/`; **modified** for Dumbo v2 (`elephant_datapath.vhd`, `CryptoCore.vhd`); other files identical to upstream | same |

`lwc/` and `core_v1/` are byte-identical to upstream. Do not edit them.
`diff -r core_v1 core_v2` shows exactly what the v2 port changed.
`core_v1/elephant_constants.vhd` keeps upstream `PERM_ROUNDS_PER_CYCLE := 10`
(GMU's docs describe arch-1 as 1 round/cycle; set it to 1 only for benchmarking).

License: GNU GPL v3, as stated in the file headers. The upstream repo has no
LICENSE file of its own; see https://www.gnu.org/licenses/gpl-3.0.txt.
`filelist.txt` in each core folder is ours (compile order from upstream `source_list.txt`).
