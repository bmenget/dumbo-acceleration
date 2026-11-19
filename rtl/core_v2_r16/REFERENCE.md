# core_v2_r16: reference point, not an optimization

`core_v2` with `PERM_ROUNDS_PER_CYCLE = 16` (5 cycles per permutation). That is the only difference
(`diff -r rtl/core_v2 rtl/core_v2_r16`). Part of the rounds-per-cycle comparison; see `rtl/core_v2_r1/REFERENCE.md`.
