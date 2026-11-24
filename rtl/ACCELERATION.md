# Speeding up Dumbo v2: options A–N

How each optimization works, which files it changes, and what it bought. Options were added one at a time, each
core on top of the previous one (naming in [README.md](README.md)). Each core's own `README.md` has its full
schedule, synthesis runs and critical paths; this file is the overview. Algorithm background is in
[../DUMBO_V2.md](../DUMBO_V2.md), and the v1→v2 port in [brody/base_r10/README.md](brody/base_r10/README.md).

## 1. Where the baseline spends its time

```
LWC (shared/lwc/, frozen) ── PreProcessor / PostProcessor / header FIFO
└─ CryptoCore            control FSM, perm_cnt_int, data_cnt_int
   └─ elephant_datapath  ms_reg (state), tag_out, load_data_output, mask muxes
      ├─ elephant_perm          Spongent-π[160], PERM_ROUNDS_PER_CYCLE rounds, combinational
      └─ elephant_datapath_lfsr mask window φ^(a-1), φ^a, φ^(a+1)
```

`brody/base_r10` runs one permutation at a time: `ms_reg → 10 rounds → ms_reg`, 8 cycles per call
([elephant_datapath.vhd:200-201](brody/base_r10/elephant_datapath.vhd#L200-L201)).

| Per 20 B block | Cycles | Permutation | Other |
|---|---|---|---|
| Plaintext | 26.85 | 16 (keystream + MAC) | about 11 |
| AD | 16.05 | 8 | about 8 |

"Other" is a setup and an unmask cycle per permutation, the 5-word load or stream, padding, and the nonce
reload. On the long profile the permutation is busy 56% of the time and **never overlaps I/O**. So there are
two targets: the permutation cycles (more hardware working at once: A, C, D, E, G) and the overhead that
never overlaps them (B, F).

## 2. Summary

Cycles are per 20 B plaintext block on long messages; throughput is long-message plaintext. Bold = current
best of its line.

| | Option | Core | cyc/blk | MHz | LUT | Mbps | Kbps/LUT |
|---|---|---|---|---|---|---|---|
| – | baseline, 10 rounds/cycle | `brody/base_r10` | 26.85 | 90.5 | 2918 | 539 | 185 |
| A | Unroll: rounds per cycle 1–16 | `brody/base_r1` … `base_r16` | 170–21 | 168–59 | 1534–3874 | ≤ 599 | ≤ 290 |
| B | Overlap I/O with the permutation | `brody/r4_B` | 42.81 | 184.3 | 1882 | 689 | 366 |
| C | Two permutation units | `brody/r4_BtoC` | 21.74 | 169.5 | 2736 | 1247 | 456 |
| D | Two pipeline stages per unit (4 calls in flight) | `brody/r4_BtoD` | 10.87 | 147.8 | 4732 | 2175 | 460 |
| E | Staggered calls (each on its own schedule) | `brody/r4_BtoE` | 9.88 | 163.8 | 5639 | 2652 | 470 |
| F | Fast loader (no decision cycle per block) | `brody/r4_BtoF` | 9.88 | 162.4 | 5631 | 2629 | 467 |
| G | 8 slots + shorter control paths | `brody/r4_BtoG` | 4.94 | 161.2 | 7295 | 5219 | 715 |
| H | Load into stage 0 only; mask delay line | `brody/r4_BtoH` | 4.94 | 174.6 | 5496 | 5653 | 1029 |
| I | Register slices on both wrapper handshakes | `brody/r4_BtoI` | 4.94 | 182.5 | 5467 | 5909 | 1081 |
| J | Mask = A ⊕ B on 2-bit selects (area) | **`brody/r4_BtoJ`** | 4.94 | 182.4 | 5396 | 5906 | 1094 |
| K | No combinational path through the core | `attic/brody/r2_BtoK` | 4.94 | 204.2 | 5762 | 6611 | 1147 |
| L | Input buffer data select from registers | **`brody/r2_BtoL`** | 4.94 | 208.0 | 5742 | 6734 | 1173 |
| M | No mask delay line (Logan's idea): **not adopted** | `merged/r2_BtoM` | 4.94 | 200.8 | 5725 | 6501 | 1136 |
| I+L | Our I and L on Logan's 20×2 ring | **`merged/ring40_IL`** | 4.97 | 249.2 | 5700 | 8021 | 1407 |
| N | 16×2 ring with two entry/exit points | **`merged/ring32_ILN`** | 4.94 | 247.1 | 5176 | 8000 | **1546** |

K, L and M were built on the r2 line: the same design at 2 rounds per stage (2 × 8 stages), `brody/r2_BtoH` →
`attic/brody/r2_BtoI`, `r2_BtoJ`, `r2_BtoK` → `brody/r2_BtoL`.

**The arc in four steps.**
1. **Unrolling alone gives at most ×1.11** (A, R = 8): above about 4 rounds per cycle the rounds set the clock,
   so Fmax falls as fast as the cycle count.
2. **Cycles (B–G):** overlap, then more calls in flight, then keeping every slot full. After G both PT and AD are
   at the 32-bit bus limit of 5 cycles per block, so from then on only clock and area can improve.
   Efficiency stays flat (~460 Kbps/LUT) from C to F, because area grows as fast as throughput.
3. **Area and clock (H–L):** H and J remove muxes that only flexibility needed; I, K and L remove control paths
   that ran from the wrapper's handshake into 160-bit registers. Same cycles, ×1.5–1.6 Kbps/LUT over G.
4. **Logan's ring (I+L, N):** his ring already had a higher clock; our I and L add another 12%, and N cuts the ring
   to the 32 rounds per cycle the bus can actually use.

**Files each option touches in our VHDL cores** (✎ = edited, · = unchanged; K and L change `CryptoCore.vhd`
only):

| File | A | B | C | D | E | F | G | H | I | J |
|---|---|---|---|---|---|---|---|---|---|---|
| `elephant_constants.vhd` | ✎ R | · | · | ✎ | ✎ | · | ✎ | ✎ | · | · |
| `elephant_perm.vhd` | ✎ new R only | · | · | · | · | · | ✎ | · | · | · |
| `elephant_datapath.vhd` | · | ✎ | ✎ | ✎ | ✎ rewrite | · | ✎ | ✎ | ✎ | ✎ |
| `elephant_datapath_lfsr.vhd` | · | · | ✎ | ✎ | ✎ | · | · | · | · | · |
| `CryptoCore.vhd` | · | ✎ | ✎ | ✎ | ✎ rewrite | ✎ | ✎ | ✎ | ✎ | ✎ |
| `profile.txt` | · | · | ✎ | ✎ | ✎ | · | ✎ | ✎ | · | · |

## 3. A: unroll more rounds per cycle

`elephant_perm` already chains `PERM_ROUNDS_PER_CYCLE` rounds; changing that constant (R) gives 80/R cycles per
permutation and a longer critical path. The `brody/base_rN` cores differ from `base_r10` only in R.

- R = 8 is the fastest (599 Mbps, ×1.11); R = 4 the most efficient (290 Kbps/LUT); R = 16 drops to 58.5 MHz.
- `base_r1` is the like-for-like match to the published `Elephant_GMU`: same cycles per block (170 vs about 171),
  same 16 B throughput, slower only through its clock.
- GMU's round-constant tables exist only for R ∈ {1, 4, 5, 8, 10, 16}; from G on, the constants are generated for
  any R.
- Even at R = 80 a block keeps about 11 non-permutation cycles, so the rest of the work had to be architectural.
  We continued at R = 4 per stage (and later 2).

## 4. B: overlap I/O with the permutation

The baseline FSM is strictly sequential per block: keystream permutation, stream 5 words, MAC permutation.
B runs **MAC(k) while block k+1 streams**, using a keystream buffer (`ks_reg`) computed just before.

- **Datapath:** `ks_reg` (160 FF); the input select became `src ⊕ mask`, with a new cur ⊕ next mask leg for
  KS(k+1); the nonce comes straight from `npub_out`.
- **Control:** a block loader that runs in any state, alongside a permutation scheduler; a `job` register says
  what the running permutation is for. AD block j+1 also fills while block j permutes.
- KS(k+1) and MAC(k) both use the LFSR window at a = k+1, so the LFSR is unchanged.

**Result** (against `base_r4`): PT 50.74 → 42.81 cycles per block, AD 28.08 → 22.06; I/O-only cycles
12.6% → 0.3%; +158 FF, about +80 LUT. KS(k+1) still has nothing to overlap with on one unit.

## 5. C: two permutation units

Elephant is a parallel mode: masks depend only on L and the block index, so keystream and MAC calls of different
blocks are independent. C adds a second `elephant_perm` and state register, running in lockstep with the first.

- **Pairing:** unit A runs MAC(k) while unit B runs **KS(k+2)**, not KS(k+1), so block k+1 can stream from a
  keystream computed one round earlier and B's overlap survives. That needs φ^k, φ^(k+2) and φ^(k+3) at once: the
  LFSR window grows by one mask (176 → 184 bits).
- **AD** runs in pairs (a second 160-bit input buffer; tag ⊕= A ⊕ B).

**Result:** PT 42.81 → 21.74, AD 22.06 → 11.19; +854 LUT, +329 FF; 184.3 → 169.5 MHz (control fanout into the
160-bit muxes became critical). ×1.81 throughput, +25% Kbps/LUT.

## 6. D: two pipeline stages per unit

Each unit becomes an 8-round loop cut into two 4-round stages, so the clock target is unchanged but **4 calls
are in flight**. Logically that is the same hardware as four R = 4 units; the speedup comes from the calls in
flight, not from shorter stages. Calls move in lockstep batches: a batch of up to 4 loads together, runs 20
cycles and unloads together.

- **Datapath:** 4 slots, each with an input buffer and a mode-selected source and mask; 2 keystream buffers; a tag
  XOR over any subset of slots; a 7-mask LFSR window that can step 1, 2 or 4 at once.
- **Control:** a batch loader and a 4-slot scheduler; `key_out` loads straight from the permutation output and the
  loader's `batch_done` is registered (both to shorten paths).

**Result:** PT 21.74 → 10.87, AD 11.19 → 6.50; 147.8 MHz, 4732 LUT; ×1.74 throughput but Kbps/LUT flat (460).
Critical path: `batch_done` → loader handshake → PostProcessor.

## 7. E: staggered calls

Lockstep batches wait for their slowest input and pay setup and unmask cycles every batch. In E every stage
register carries **its own call and round counter**, so each call starts as soon as its input is ready and
finishes 20 cycles later. Same 2 units × 2 stages × 4 rounds.

- **Datapath (rewritten):** one shared load `x = src ⊕ mask` (one call starts per cycle); a 4-entry mask store for
  unmasking; registered result and mask; 2 input buffers; a 3-deep keystream FIFO, so keystream runs up to 3
  blocks ahead, starting during AD.
- **LFSR:** two windows (AD/MAC and keystream), so they can be at different block indices.
- **Control (rewritten):** an issue engine, one cycle ahead, picks the oldest request for a register that frees up:
  KEY > FIN > next full input buffer > keystream. The loader now reaches a segment early, so it waits for
  `bdi_type` (with a timeout) to tell an empty segment.

**Result:** PT 10.87 → 9.88, AD 6.50 → 6.02; 163.8 MHz, 5639 LUT (+907); 470 Kbps/LUT. PT is now
**slot-bound**: 2 calls × 20 cycles / 4 slots = 10 cycles per block.

## 8. F: fast loader

The loader spent a decision cycle after every block (a 5-word block took 6 cycles). F makes the decision in the
last word's cycle. `CryptoCore.vhd` only.

**Result:** AD 6.02 → 5.01, the 32-bit bus limit (5182 Mbps long AD); PT unchanged (slot-bound); area and clock
unchanged.

## 9. G: double the slots, shorten the control paths

With staggered calls, cycles per block ≈ 160 / (rounds computed per cycle). 4 units × 2 stages × 4 rounds = 32
rounds per cycle brings PT to 5. To keep the clock, G also shortens F's three tied critical paths.

- **Constants:** generic `NUNIT` × `NSTAGE` rings; keystream FIFO `NKS` = 6 (3, 4, 5 give 9.9, 7.5, 5.9 cycles per
  block; `reports/nks_study.csv`); round constants generated for any rounds per stage.
- **Paths:** the issue engine decides two cycles ahead through a registered `x`; round constants registered next to
  each round counter; the keystream head shifts one word per message word (no `data_count` mux on `bdo`).

**Result:** PT 9.88 → **4.94**, AD 5.00: both at the bus limit. 161.2 MHz, 7295 LUT (+1664); 5219 Mbps (×1.99),
715 Kbps/LUT. Short messages pay 2–3 cycles for the extra issue stage.

## 10. H: the same cycles in less area

G's call could enter any stage register, which costs a load mux per register, an 8:1 result mux and an indexed
mask store. If calls per ring divide evenly (`PERM_CYCLES mod NSTAGE = 0`), a call loaded into stage 0 always
finishes in the last stage, so **loading only into stage 0** costs no cycles.

- 2 rings × 4 stages (fewer load muxes; 2:1 result mux). Calls finish in load order, so masks ride a 20-deep SRL
  delay line instead of the mask store.

**Result:** same cycles; 5496 LUT (−25%), 3370 FF (−30%); 174.6 MHz (+8%); 1029 Kbps/LUT (×1.44). The rounds are now
51% of the LUTs, close to the floor of 80 per round. Critical path: the frozen wrapper's PreProcessor → our
loader handshake. The same RTL at 2 rounds per stage (`brody/r2_BtoH`) was worse on every metric, because the
wrapper path sets the clock in both.

## 11. I: take the wrapper handshake off the critical path

H's worst path started in the PreProcessor, but six of its seven levels were our loader turning "word accepted"
into enables on 160-bit registers. I puts 2-entry register slices (skid buffers) on `bdi` and `bdo`, so
`bdi_ready` and `bdo_valid` are flip-flops and the loader decides on a registered word. The keystream head's next
value is built from registers, with the accept as the last mux select.

**Result:** same cycles per block, +1–2 cycles per message; +166 FF; 182.5 MHz (+4.5%); 1081 Kbps/LUT. The
rounds are now the critical path. At 2 rounds per stage (`attic/brody/r2_BtoI`) it now pays off: 201.4 MHz,
6521 Mbps, but 16 B messages take 152 cycles (r4: 92).

## 12. J: a smaller source and mask select

The largest non-round logic was each new call's input, `x = source ⊕ mask` (802 LUT cells), because the call kind
was decoded into a 3-way source and a 5-way mask select. Every mask is one term from {0, φ^k, keystream φ^k, L} XOR
one from {0, φ^(k+2), φ^(k+1)}, so three 4:1 muxes on registered 2-bit selects do the same job.

**Result:** same cycles and clock; 640 LUT cells for source and mask; 5396 LUT (−1.3%, about Vivado's spread);
1094 Kbps/LUT. **End of the r4 line.** Alternative Vivado flows on I's RTL (timing-driven: 191 MHz but +17%
LUT; area: 5100 LUT at 170 MHz) did not beat the standard flow per LUT (`reports/flow_results.csv`).

## 13. K: no combinational path through the core (r2)

After I and J at 2 rounds per stage, the critical path still ran wrapper → core → wrapper: PreProcessor →
`key_valid` → core control → 32-bit tag compare → `msg_auth` → PostProcessor (12 levels). K makes every core
output a register or a decode of registers (idea from Logan's core):
- The tag compare only clears a `tag_verified` register; a new `AUTH` state presents `msg_auth` from registers.
- `key_ready` no longer waits for `key_valid` (the LWC handshake allows ready before valid).

**Result:** +1 cycle per decryption; 197.6 → 204.2 MHz; 1147 Kbps/LUT.

## 14. L: input buffer data select from registers (r2)

K's worst path ran from the input slice's valid through the loader's accept (fanout 167) into `saving_bdo`, which
picks what an input buffer stores (ciphertext on encrypt, the input word on decrypt), and on to the D input of every
buffer bit. L decodes `saving_bdo` from registers only, so the accept drives just the write enable.

**Result:** same cycles; 208.0 MHz, 5742 LUT, 1173 Kbps/LUT. **End of the r2 line and our best own core.**
J → K → L is 197.6 → 204.2 → 208.0 MHz: each step is within Vivado's spread on its own, but each removed path is
confirmed in the timing reports. The remaining limits are many short, routing-bound input-side paths.

## 15. M: no mask delay line (tried, not adopted)

From Logan's core: instead of carrying each call's mask to its result through the SRL delay line, AD/MAC masks are
summed into an accumulator at load time and the keystream masks are rebuilt at the output by a second LFSR window.

**Result:** correct and same cycles, but the new 6-input result mux and second window cost what the 320 SRLs did:
−17 LUT, +333 FF, and 200.8 MHz (a new path into both windows). An SRL32 stores 32 cycles of a bit in one LUT,
which is hard to beat. L stays the r2 core.

## 16. Logan's ring with our I and L

Logan's `CryptoCorePipe` is a ring of S stages × K rounds (`logan/ring40` = 20 × 2) with a higher clock than our
cores (222.5 MHz). In our flow its ring had slack; the clock was set by the wrapper handshake reaching his 160-bit
registers, the same problem I solved for us.
- **`merged/ring40_I`:** our register slices on `bdi` and `bdo` in a shim around his unmodified core:
  222.5 → 245.2 MHz (+10%) for +55 LUT.
- **`merged/ring40_IL`:** a slice on the key channel too, plus L inside his core (the `KB` and `TI` data selects
  from registers): 249.2 MHz, 8021 Mbps, **the fastest core**.
- **`merged/ring20_IL`:** the same on his 10 × 2 ring: 215.4 → 244.1 MHz, 4807 Mbps in 3865 LUT.

## 17. N: a 32-round ring with two entry/exit points

The bus limit needs 2 calls × 80 rounds per 5 cycles = 32 rounds per cycle; the 20 × 2 ring carries 40. His ring
needs S·K to divide 80 (a call leaves where it entered), which 32 doesn't. At 16 × 2 a call takes 2.5 laps and
finishes opposite its entry, so N adds a **second entry/exit point 8 stages away**: a call entering at one leaves
at the other, which refills the slot in the same cycle.

- `spongent_perm_pipe.sv`: parameter `P` (entry/exit points), one insertion mux and finish detector per point; the
  finish flag is registered a cycle ahead to keep it off the insertion path. Interface, latency and in-order
  results are unchanged.

**Result:** same cycles (4.94 per PT block); −524 LUT (−9%), −670 FF; 247.1 MHz (within noise of ring40_IL);
8000 Mbps and **1546 Kbps/LUT, the best of any core**.

## Design-space sweep

[brody/gen/](brody/gen/README.md) generalizes B + C + D (lockstep batches) with R (rounds per unit), S (pipeline
stages), U (units) and a fast loader; `scripts/sweep.py` ran 111 points through simulation and synthesis. Results and findings are in
[../reports/sweep/README.md](../reports/sweep/README.md).
