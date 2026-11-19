# Upstream provenance: tb/

`LWC_TB.vhd` and `LWC_TB_compatibility_pkg.vhd`: https://github.com/GMUCERG/Elephant
`src_tb/`, commit `090d1e745fa28add5d11634cec9883681e6bc763`. Unmodified (GPL v3).

LWC_TB writes `result.txt` like an exit code: `0` = pass, `1` = fail.
It stops at the first failing word (`G_MAX_FAILURES = 0`).
