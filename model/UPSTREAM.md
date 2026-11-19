# Upstream provenance: model/

SUPERCOP layout (`crypto_aead/<name>/ref/`), which cryptotvgen requires.

| Path | Source | Commit |
|---|---|---|
| `crypto_aead/elephant160v1/ref/` | https://github.com/TimBeyne/Elephant `crypto_aead/elephant160v1/ref/` | `b1a68838e1e38cae26fed906c704ea98a19425af` |
| `crypto_aead/elephant160v2/ref/` | same repo, `crypto_aead/elephant160v2/ref/` | same |

Unmodified except `elephant160v2/ref/crypto_aead.h`, an empty stub we added
(upstream `encrypt.c` includes it but the file is missing).
GMU built their v1 vectors from commit `2db38b1`; our v1 copy reproduces all 3201
of GMU's shipped vectors in simulation, so the difference doesn't matter.

`make models` builds `lib/crypto_aead/*.so` (gitignored) and checks the v2 model
against `LWC_AEAD_KAT_128_96.txt` (1089/1089).
