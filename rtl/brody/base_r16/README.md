# brody/base_r16: reference point, not an optimization

`brody/base_r10` with `PERM_ROUNDS_PER_CYCLE = 16` (5 cycles per permutation). That is the only difference
(`diff -r rtl/brody/base_r10 rtl/brody/base_r16`). Part of the rounds-per-cycle comparison; see `rtl/brody/base_r1/README.md`.
