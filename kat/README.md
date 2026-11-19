# Test vectors

| Path | What | Tracked |
|---|---|---|
| `v1/gmu/` | GMU's shipped vectors (`KAT/v1/` at GMUCERG/Elephant `090d1e7`, cryptotvgen 1.1.0), 3201 vectors | yes |
| `<spec>/gen/<set>/` | ours, from `make kat SPEC=<spec>` (cryptotvgen 1.2.0, seed 545) | no, regenerate |

Generated sets (`scripts/gen_kat.py`):
- `random`: 1000 vectors, random enc/dec and key reuse, AD/PT 0..1000 B
- `edge`: AD in {0,1,7,8,9,19,20,21,27,28,29,39,40,41,47,48,49} x PT in {0,1,19,20,21,39,40,41,59,60,61};
  each pair is an encrypt (new key) then a decrypt (same key). 374 vectors.
  AD boundaries sit at 8/28/48 B because the first block is Npub(12 B) || AD.
- `full33`: every (AD, PT) length pair 0..32 B (the 1089 combinations of the official KAT), each as
  encrypt (new key) then decrypt (same key). 2178 vectors.
- `long`: (AD,PT) in {(0,1536),(1536,0),(1536,1536),(0,4000),(4000,4000)}, enc + dec
- `badtag`: `edge` with the tag of every decrypt flipped (1 bit); expected status Failure.
  Plaintext is still expected on the output: the GMU core releases it before the tag check.
