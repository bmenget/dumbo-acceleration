# How Dumbo v2 works

A short guide to what the algorithm computes, what it costs, and how our baseline hardware (`rtl/core_v2/`)
schedules that work. For the full definition see the [Elephant v2 spec](docs/elephantv2-spec.pdf)
(Algorithms 1 and 2, Section 2.3); the C reference is
[`model/crypto_aead/elephant160v2/ref/encrypt.c`](model/crypto_aead/elephant160v2/ref/encrypt.c).

## 1. What it is
Dumbo is the primary member of the **Elephant v2** family, a NIST Lightweight Cryptography finalist. It is an
**authenticated encryption with associated data (AEAD)** scheme: it encrypts a message *and* produces a tag that
proves the ciphertext and the associated data (AD, e.g. a packet header sent in the clear) were not changed.

| Parameter | Value |
|---|---|
| Key K | 128 bits (16 B) |
| Nonce N | 96 bits (12 B); must never repeat under one key |
| Tag T | 64 bits (8 B) |
| Block / state size | 160 bits (**20 B**) |
| Primitive | Spongent-π[160] permutation, **80 rounds** |
| Mode | encrypt-then-MAC: counter-mode encryption + a masked MAC over AD and ciphertext |
| Claimed security | 112 bits, up to about 2^45.7 blocks per key |

There is no hash function and no key schedule. Everything is built from **one permutation P**, a cheap
**mask LFSR φ**, and XORs.

## 2. The three building blocks

**Spongent-π[160] (P).** A fixed, unkeyed 160-bit to 160-bit permutation. Each of the 80 rounds does:
1. XOR a 7-bit round counter into the low bits of the state and its bit-reversal into the high bits.
2. **sBoxLayer:** 40 copies of one 4-bit S-box in parallel (`0..F -> E D B 0 2 1 4 F 7 A 8 5 9 C 3 6`).
3. **pLayer:** move bit j to position 40·j mod 159 (bit 159 stays). In hardware this is just wiring.

**Mask LFSR φ.** Treat the 20-byte state as bytes x0..x19. One step moves every byte down one position
(x1 becomes x0, and so on) and computes the new x19 as `rotl3(x0) ⊕ (x3 << 7) ⊕ (x13 >> 7)`. About 8 XOR
gates; one step per block.

**Masks.** First, the expanded key **L = P(K ‖ 0)** is computed once per key. The mask for block i is
**φ^i(L)**: L stepped i times through the LFSR. Every permutation call is "masked": XOR a mask in, run P,
XOR the same mask out. That turns the unkeyed P into a keyed function.

## 3. Encryption, step by step
Inputs: K, N, AD, message M. Blocks are 20 B and indexed from 0.

```
Setup     L = P(K || 0)                                  (once per key, reusable)

Encrypt   for each message block i:
            ks_i = P( (N||0) ⊕ φ^i(L) ⊕ φ^(i+1)(L) ) ⊕ φ^i(L) ⊕ φ^(i+1)(L)
            C_i  = M_i ⊕ ks_i                            (last block truncated, no padding)

MAC       A = N || AD || 0x01 || 0..0   split into 20 B blocks A_0, A_1, ...
          C' = C || 0x01 || 0..0         split into 20 B blocks C'_0, C'_1, ...
          T  = A_0                                         (first block NOT permuted)
          T ^= P( A_j  ⊕ φ^j(L) ) ⊕ φ^j(L)                   for each AD block j >= 1
          T ^= P( C'_i ⊕ φ^i(L) ⊕ φ^(i+2)(L) ) ⊕ (same mask)   for each ciphertext block i

Finalize  T = P( T ⊕ L ) ⊕ L
          tag = first 8 bytes of T
```
In words:
- **Encryption is counter mode.** The "counter" is the block index hidden in the mask, and the permutation
  input is always the padded nonce.
- **The MAC is a sum.** Every AD block and every ciphertext block is masked, permuted, unmasked, and XORed into
  a 160-bit accumulator. One last permutation (masked with L) turns the sum into the tag.
- **Padding always adds a 0x01 byte**, so a length that is an exact multiple of 20 B gets one extra padding
  block. The nonce rides in the first AD block, so AD block boundaries fall at 8, 28, 48 ... bytes of AD.

**Decryption** is the same computation: XOR the same keystream into C to get M, and compute the MAC over the
received C (encrypt-then-MAC). The recomputed tag is compared to the received one. Our hardware releases the
plaintext before the tag check finishes, then reports pass/fail.

## 4. Computational profile
Almost all of the work is permutation calls. For a message with `AD` bytes of associated data and `M` bytes of
message:

| Work | Count | Notes |
|---|---|---|
| AD-MAC permutations | `floor((12 + AD) / 20)` | the first AD block is free |
| Keystream permutations | `ceil(M / 20)` | 0 for an empty message |
| Ciphertext-MAC permutations | `floor(M / 20) + 1` | always at least 1, from padding |
| Final tag permutation | 1 | |
| Key expansion L = P(K‖0) | 1 per new key | skipped when the key is reused |
| LFSR steps, 160-bit XORs | a few per block | negligible next to an 80-round permutation |

| Workload (AD + M bytes) | Permutations (key reused) |
|---|---|
| 16 + 16 | 4 |
| 64 + 64 | 12 |
| 0 + 1536 | 155 |
| 1536 + 0 | 79 |
| 1536 + 1536 | 232 |

So a long message costs about **2 permutations per 20 B of message** (keystream + MAC) and **1 per 20 B of AD**.
Each permutation is 80 rounds of 40 S-boxes, which makes Dumbo slow per byte. In NIST's final-round report
it was slower than AES-GCM on nearly every software platform, and far behind the other finalists in eBACS
cycles-per-byte figures.

**What can run in parallel.** This is Elephant's distinguishing feature: it is the only parallel-mode finalist.
- Masks depend only on L and the block index, never on data. So any block's mask can be computed ahead of time.
- Keystream permutations for different blocks are independent.
- AD-MAC permutations are independent of each other and of the message.
- A ciphertext-MAC permutation needs that ciphertext block. When encrypting, it must follow the keystream
  permutation for the same block. When decrypting, C is an input, so both can run at once.
- Only the final tag permutation must wait for all the others.

The C reference shows this structure: each loop iteration does one keystream, one ciphertext-MAC and one
AD-MAC permutation, with no data dependency between them.


