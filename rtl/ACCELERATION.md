# Speeding up brody/base_r10: options and where they land in the RTL

This is a plan for the optimized cores (`rtl/brody/`, `rtl/merged/`; naming in [README.md](README.md)). It covers the
options A–N for making Dumbo v2 faster (and smaller), which files each one changes, and how. Sections 3–12 cover
A–J; K–N are summarized in the tables below and described in their cores' `README.md`. Line references are to `brody/base_r10` as of 2026-11-19.
Background on the algorithm is in [../DUMBO_V2.md](../DUMBO_V2.md). The v1→v2 port is described in
[brody/base_r10/README.md](brody/base_r10/README.md).

**Status (2026-11-23)**

| Option | State |
|---|---|
| A | Swept: `brody/base_r1`, `r4`, `r5`, `r8`, `r16` (see `reports/benchmark.csv`) |
| B | **Done:** [brody/r4_B/](brody/r4_B/README.md), on top of `brody/base_r4`. Section 4 describes how it was built. |
| C | **Done together with B:** [brody/r4_BtoC/](brody/r4_BtoC/README.md). It pairs MAC(k) with KS(k+2), not KS(k+1) as section 5 suggests, so B's overlap survives (needs a 4th mask, +8 LFSR FF). AD blocks also run in pairs. 21.74 cycles per PT block, 169.5 MHz, 2736 LUT. |
| D | **Done on top of B + C:** [brody/r4_BtoD/](brody/r4_BtoD/README.md). Two 4-round stages per unit, 4 calls in flight. That's logically equal to 4 R=4 units; splitting R=4 into 2 + 2 would not have reduced cycles. 10.87 cycles per PT block, 147.8 MHz, 4732 LUT, 2175 Mbps, 460 Kbps/LUT (flat vs r4_BtoC). |
| E | **Done on top of B + C + D:** [brody/r4_BtoE/](brody/r4_BtoE/README.md). Same 2 units × 2 stages × 4 rounds, but staggered calls: each stage register carries its own call and round counter, one call starts per cycle as soon as its input is ready, keystream runs up to 3 blocks ahead. 9.88 cycles per PT block (slot-bound), 6.02 per AD block, 163.8 MHz, 5639 LUT, 2652 Mbps, 470 Kbps/LUT. |
| F | **Done on top of E:** [brody/r4_BtoF/](brody/r4_BtoF/README.md). Fast loader: a block completes in its last word's cycle. AD at the bus limit (5.01 cycles per block, 5182 Mbps); PT unchanged; 162.4 MHz, 5631 LUT. |
| G | **Done on top of F:** [brody/r4_BtoG/](brody/r4_BtoG/README.md). Generic NUNIT × NSTAGE rings, built as 4 × 2 × 4 rounds (8 calls in flight), keystream FIFO 6 deep, and r4_BtoF's three tied paths shortened (issue two cycles ahead through a registered x, registered round constants, keystream head shifted per word). PT at the bus limit too (4.93 cycles per block); 161.2 MHz, 7295 LUT, 5219 Mbps long PT, 715 Kbps/LUT. |
| H | **Done on top of G:** [brody/r4_BtoH/](brody/r4_BtoH/README.md). Same cycles as G with less area: new calls go into stage 0 only (2 rings × 4 stages), so stages 1.. have no load mux, the result mux is 2:1 and a 20-deep SRL delay line replaces the mask store. 174.6 MHz, 5496 LUT (−25%), 5653 Mbps long PT, 1029 Kbps/LUT. The same RTL at 2 rounds per stage, [brody/r2_BtoH/](brody/r2_BtoH/README.md), is worse on every metric (171.4 MHz, 5786 LUT, 16 B in 150 cycles): the wrapper handshake sets the clock in both. |
| I | **Done on top of H:** [brody/r4_BtoI/](brody/r4_BtoI/README.md). Register slices (2-entry skid buffers) on `bdi` and `bdo`, and the keystream head's next value selected by the word accept in one last mux. The wrapper → loader path is gone; the rounds set the clock. 182.5 MHz, 5467 LUT, 5909 Mbps long PT, 1081 Kbps/LUT, +1–2 cycles per message (16 B in 92). At 2 rounds per stage, [attic/brody/r2_BtoI/](attic/brody/r2_BtoI/README.md) now pays off: 201.4 MHz, 6521 Mbps long PT, 1114 Kbps/LUT, at the wrapper's own clock limit, but 16 B in 152 cycles. |
| J | **Done on top of I:** [brody/r4_BtoJ/](brody/r4_BtoJ/README.md). Area only: each new call's mask is A ⊕ B with A ∈ {0, φ^k, keystream φ^k, L} and B ∈ {0, φ^(k+2), φ^(k+1)}, and the source, A and B are 4:1 muxes on registered 2-bit selects instead of a decode of the call's kind. Source / mask logic 802 → 640 LUT cells; 182.4 MHz, 5396 LUT (−1.3%), 1094 Kbps/LUT. Same cycles. At 2 rounds per stage, [attic/brody/r2_BtoJ/](attic/brody/r2_BtoJ/README.md): 197.6 MHz, 5767 LUT (−85), 1109 Kbps/LUT, a tie with r2 I within Vivado noise. |
| K | **Done on top of r2 J:** [attic/brody/r2_BtoK/](attic/brody/r2_BtoK/README.md). Timing only: r2 J's critical path ran wrapper → core → wrapper (PreProcessor → tag compare → `msg_auth` → PostProcessor, 12 levels), not through the wrapper alone. The tag check now only updates `tag_verified`, a new `AUTH` state shows `msg_auth` from registers, and `key_ready` no longer waits for `key_valid`. 204.2 MHz (+3.3%), 5762 LUT, 6611 Mbps long PT, 1147 Kbps/LUT; +1 cycle per decryption, encryption unchanged. Next limit: `ih_v` / `ih` → input buffers. Idea from Logan's cores (`rtl/logan/src/`). |
| L | **Done on top of K:** [brody/r2_BtoL/](brody/r2_BtoL/README.md). Timing only: `saving_bdo` (store ciphertext or word into the input buffer) is decoded from registers instead of set by the loader's accept, so the accept (`ih_v`, `ks_cnt`, …) reaches only the buffers' write enable, not their data mux. 208.0 MHz, 5742 LUT, 6734 Mbps long PT, 1173 Kbps/LUT; same cycles as K. Remaining limits near 220 MHz: input-side, routing-bound paths (wrapper → `wait_cnt`, `ih → ib`, `ih → kh`). |
| M | **Tried on top of L, not adopted:** [merged/r2_BtoM/](merged/r2_BtoM/README.md). No mask delay line (Logan's idea): AD / MAC masks summed into `macc` at load and fed to FIN, keystream masks rebuilt at the output by a second KS window. Correct (all sets pass, same cycles), but 5725 LUT (−17) and +333 FF: the new 6-input result mux and second window cost about what the 320 SRLs did. 200.8 MHz (new path `ks_st` → both windows). L stays the r2 core. |
| N | **Done on Logan's ring:** [merged/ring32_ILN/](merged/ring32_ILN/README.md), on top of [merged/ring40_IL/](merged/ring40_IL/README.md) (his 20×2 ring with our I and L: 249.2 MHz, 8021 Mbps). A 32-round ring (16 stages × 2 rounds) with two entry / exit points, so a call can finish opposite where it entered: the 32 rounds per cycle long messages need at the bus limit, not 40. Same cycles; 247.1 MHz, 5176 LUT (−524), 8000 Mbps long PT, **1546 Kbps/LUT**, the best of any core. |
| Sweep | [brody/gen/](brody/gen/README.md) generalizes B + C + D with R (rounds per unit), S (pipeline stages, a pure register knob), U (units) and a fast loader; `scripts/sweep.py` explores the grid. Built and elaborated; not yet simulated. |

## 1. Where the time goes today

**RTL map** (only the optimized cores get edited; `shared/lwc/` and `gmu/arch1_v1/` are frozen):

```
LWC (lwc/LWC.vhd, frozen) ── PreProcessor / PostProcessor / header FIFO
└─ CryptoCore            brody/base_r10/CryptoCore.vhd           control FSM, perm_cnt_int, data_cnt_int
   └─ elephant_datapath  brody/base_r10/elephant_datapath.vhd    ms_reg (state), tag_out, load_data_output, mask muxes
      ├─ elephant_perm          brody/base_r10/elephant_perm.vhd          Spongent-π[160], combinational
      └─ elephant_datapath_lfsr brody/base_r10/elephant_datapath_lfsr.vhd mask window φ^(a-1), φ^a, φ^(a+1)
```

**The permutation loop:** `ms_reg → elephant_perm (PERM_ROUNDS_PER_CYCLE rounds) → ms_reg`
([elephant_datapath.vhd:200-201](brody/base_r10/elephant_datapath.vhd#L200-L201)). With the current
`PERM_ROUNDS_PER_CYCLE = 10`, one permutation takes 8 cycles.

**Baseline numbers** (`reports/benchmark.csv`, `reports/profile.csv`):

| | Cycles per 20 B block | Of which permutation | Of which other |
|---|---|---|---|
| Plaintext block | 26.85 | 16 (keystream + MAC) | about 11 |
| AD block | 16.05 | 8 | about 8 |

The "other" cycles are `PRE_PERM`/`POST_PERM` (1 cycle each per permutation), the 5-word load or stream
in `MDATA_S`/`AD_S`, a padding cycle, and the nonce reload in `MDATA_NPUB`.
Profile of the long workload: 55.7% of cycles have the permutation busy, **0.0% overlap a permutation with
I/O**, 23.2% are I/O only, and 21.2% are neither.

So there are two separate targets:
- **The 16 permutation cycles per block.** Options A, C and D go after these.
- **The roughly 11 overhead cycles per block, which never overlap with the permutation.** Option B goes
  after these. Once A, C or D shrinks the permutation cycles, this overhead becomes the larger share, so
  B gets more valuable the further the others go.

The cycle estimates below are rough per-block models for long messages. Measure the real numbers with
`make cycles` and `make profile`.

## 2. The options at a glance

| | Option | Gets cycles per PT block to about | Fmax | Area | Difficulty |
|---|---|---|---|---|---|
| A | Unroll more rounds per cycle | 19 (R=20), 15 (R=40) | drops about 1/R | grows with R | constants only (plus one ROM table for R=20/40/80) |
| B | Overlap I/O with the permutation | 21 (measured at R=4: 50.7 → 42.8) | about the same | +160 FF (measured +158 FF, about +80 LUT) | FSM rework |
| C | Two permutation units | 19 alone, about 10–12 with B | about the same | about 2× permutation, +160 FF | datapath + FSM rework |
| D | Pipeline the permutation and interleave two calls | same cycles as baseline, at about 2× the clock | rises | +160–320 FF, same round logic | permutation + datapath + FSM |
| E | Stagger the calls (each in-flight call runs on its own schedule) | slots bound it: 2 calls × 20 cycles / slots (measured 10.87 → 9.88 on r4_BtoD) | measured 147.8 → 163.8 MHz | measured +907 LUT, +1018 FF (mask store, keystream FIFO, per-register round index) | datapath + FSM rewrite |
| F | Fast loader (no decision cycle per block) | PT unchanged (slot-bound); AD 6.02 → 5.01, the 32-bit bus limit | same | none (measured −8 LUT) | loader only |
| G | Double the slots (4 units × 2 stages) and shorten the control paths | 160 / (total rounds per cycle): 9.86 → 4.93, the bus limit | measured 162.4 → 161.2 MHz | measured +1664 LUT, +1411 FF | generic ring + issue engine |
| H | Load new calls into stage 0 only; mask delay line instead of mask store | same as G (4.93) | measured 161.2 → 174.6 MHz | measured −1799 LUT, −1471 FF | issue engine + datapath |
| I | Register both wrapper handshakes; keystream head selected by the accept last | same (4.94); +1–2 cycles per message | measured 174.6 → 182.5 MHz (2 rounds/stage: 171.4 → 201.4) | measured +166 FF, LUT unchanged | loader + keystream head |
| J | Mask = A ⊕ B; source and both terms on registered 2-bit selects | same | same (182.4 MHz) | measured −71 LUT (−162 LUT cells) | issue engine + datapath |
| K | No combinational path through the core: tag result and `msg_auth` from registers, `key_ready` not gated by `key_valid` | same; +1 cycle per decryption | measured at 2 rounds/stage: 197.6 → 204.2 MHz | none (5767 → 5762 LUT) | main FSM only |
| L | Input buffer data select (`saving_bdo`) from registers, not the word accept | same | measured at 2 rounds/stage: 204.2 → 208.0 MHz | none (5762 → 5742 LUT) | loader only |
| M | No mask delay line: masks summed at load (tag) or rebuilt at the output (keystream) | same | measured 208.0 → 200.8 MHz | −17 LUT, +333 FF: not adopted | datapath + issue engine |
| N | Logan's ring at 16 × 2 = 32 rounds with two entry / exit points | same (4.94, the bus limit) | measured 249.2 → 247.1 MHz (noise) | measured −524 LUT, −670 FF | ring (`spongent_perm_pipe.sv`) + issue logic |

**Which files each option touches** (✎ = edit, · = unchanged):

| File | A | B | C | D | E | F | G | H | I | J |
|---|---|---|---|---|---|---|---|---|---|---|
| `elephant_constants.vhd` | ✎ R value | · | · | ✎ stage count | ✎ slot count, FIFO depth, call kinds | · | ✎ NUNIT, NSTAGE, NKS, ring functions, round-constant table | ✎ NUNIT 2, NSTAGE 4, no `vslot` | · | · |
| `elephant_perm.vhd` | ✎ only for R ∉ {1,4,5,8,10,16} | · | · (instantiated twice) | ✎ pipeline register, per-stage constants | · (each stage gets its own round index) | · | ✎ takes registered round constants | · | · | · |
| `elephant_datapath.vhd` | · | ✎ keystream buffer, cur ⊕ next mask, nonce source | ✎ second unit, second state register, masks, tag XOR | ✎ second holding register, muxes | ✎ rewrite: shared load, mask store, result register, 2 input buffers, keystream FIFO | · | ✎ registered x, generic rings, binary result index, shifting keystream head | ✎ stage-0 load, last-stage result, mask delay line, FIFO write on every push | ✎ keystream head: candidates from registers, accept selects last | ✎ source / mask terms as 4:1 muxes on 2-bit selects |
| `elephant_datapath_lfsr.vhd` | · | · | · (possibly +8 FF, see C) | · | ✎ two mask windows (MAC/AD and keystream) | · | · | · | · | · |
| `CryptoCore.vhd` | · | ✎ schedule | ✎ schedule | ✎ schedule | ✎ rewrite: issue engine | ✎ loader | ✎ issue engine two cycles ahead, round constants | ✎ issue to stage 0 only, finish in last stage, no ring phase | ✎ input and output register slices, segment check on the slice | ✎ issue decision registers the three selects |
| `profile.txt` | · | · | ✎ one probe per unit | ✎ probe per in-flight call | ✎ probe per stage register | · | ✎ 8 probes | ✎ 8 probes | · | · |
| `filelist.txt` | ✎ path rename when copying the core | same | same | same | same | same | same | same | same | same |

## 3. Option A: unroll more rounds per cycle

**Idea.** `elephant_perm` already chains `PERM_ROUNDS_PER_CYCLE` rounds combinationally
(`rnd: for x ... generate`). Raising R cuts cycles per permutation (80/R) but lengthens the critical path.

**Files and changes**
- `elephant_constants.vhd`: set `PERM_ROUNDS_PER_CYCLE`. 80 must divide evenly by R.
  `PERM_CYCLES` and the `perm_cnt_int` range follow from it automatically.
- `elephant_perm.vhd`: round constants come from one ROM per supported R (`lfsr_rom16/10/8/5/4`, selected
  by `lsfr_sig_N` generates). R = 1 uses the 7-bit LFSR instead. For **R = 20, 40 or 80** add a ROM and a
  matching `generate` branch. Each ROM entry is the next R bytes of the same 80-byte constant string
  (`75 6a 54 29 53 27 …`), so it is a regrouping of the existing data. A cleaner fix: replace the
  hand-written ROMs with a function that computes the constants from the 7-bit LFSR at elaboration time.
  That makes every divisor of 80 work.
- Nothing else changes. `CryptoCore` already loops `PERM_CYCLES` times.

**What to measure.** Sweep R ∈ {1, 4, 5, 8, 10, 16, 20, 40} and plot Fmax, LUTs, and throughput/LUT. First
confirm that the permutation is the critical path at R = 10 (check the Vivado timing report). If the
wrapper or the FSM is critical instead, a smaller R will not raise Fmax.

**Limit.** Even at R = 80 a block still costs about 11 non-permutation cycles plus 2. Unrolling alone
stops paying off after R = 20 or so. It also combines with every other option, because B, C and D all
take R as a parameter.

## 4. Option B: overlap I/O with the permutation (one unit)

**Idea.** Today the FSM is strictly sequential for each block. `MDATA_NPUB` loads the nonce, then the
keystream permutation runs, then `MDATA_S` streams 5 words (PT xor keystream), then the MAC permutation
runs, then the next block starts. The I/O can't start until the keystream is in `ms_reg`, and the MAC
permutation then reuses `ms_reg`.

Reorder it to: keystream(k+1) permutation → MAC(k) permutation **while streaming block k+1**. For that, the
keystream for block k+1 has to live somewhere other than `ms_reg` while the MAC permutation uses it.

**Files and changes**
- `elephant_datapath.vhd`
  - Add `ks_reg` (160 bits), loaded from `permout` when a keystream permutation finishes.
  - Point `ms_out_mux2` (which feeds `data_bdo`) at `ks_reg` instead of `ms_reg_out`.
  - `load_data_output` already holds the incoming block separately from `ms_reg`. While the MAC
    permutation runs, it can collect C(k+1) as long as C(k) has already been moved into `ms_reg` (that
    already happens in the last `MDATA_S` cycle, `ms_en` with select `000`).
- `CryptoCore.vhd`
  - Let `MDATA_S` accept words while `PERM` runs. In practice that means merging the two states or adding
    a combined `PERM_IO` state, where `bdi_ready`/`bdo_valid` follow the `MDATA_S` rules and
    `perm_cnt_int` counts.
  - Update `calling_state`, `done_state` and `append_one` for the new order. Handle the edge cases: an
    empty message, a last block that is exactly 20 B (v2 adds an extra MAC-only padding block), and
    decryption.
- `elephant_datapath_lfsr.vhd`: check which window position each mask uses (table in section 5). With the
  order ks(k+1) then MAC(k), both masks come from the window at a = k+1, so no change is needed.

**Gain.** The roughly 6 I/O cycles per block hide behind 8 permutation cycles: about 27 → 21 cycles per
block. This option also builds most of the FSM that C and D need.

**As built ([brody/r4_B/](brody/r4_B/README.md)).** It follows the plan above, with these differences:
- **Keystream mask.** KS(k+1) needs cur ⊕ next, a mask leg `brody/base_r10` doesn't have. The 6-way select became
  `src xor mask` (`src_sel`: ms / input block / N‖0 / tag; `mask_sel`: none / prev / prev⊕next / cur⊕next / L).
- **Nonce.** It comes straight from `npub_out` (`SRC_NONCE`). Otherwise it would overwrite C(k) in
  `load_data_output` while C(k) waits for its MAC. The MAC start captures `C(k) ⊕ masks` into `ms_reg` in one
  cycle, so no separate copy cycle is needed.
- **FSM structure.** Instead of a merged `PERM_IO` state, `CryptoCore` has a block filler (loader) that runs
  in any state, plus a permutation scheduler (`AD_INIT`, `AD_WAIT`, `MSG_LFSR`, `MSG_WAIT`, `PERM`, `POST`,
  `FINAL_PRE`). `calling_state` is gone; a `job` register says what the running permutation is for.
- **AD overlap too.** AD block j+1 fills while block j permutes. This needs no extra register and saves
  about 6 of 28 cycles per AD block at R = 4.
- **LFSR start position.** The message reload starts the LFSR at a = 0, not a = 1, so every keystream uses
  cur ⊕ next.

Measured at R = 4 against `brody/base_r4`:
- **Plaintext:** 50.74 → 42.81 cycles per block.
- **AD:** 28.08 → 22.06 cycles per block.
- **Long profile:** I/O-only cycles drop from 12.6% to 0.3%.
- **Area:** +158 FF and about +80 LUT.

The remaining overhead is one setup cycle and one post cycle per permutation, plus KS(k+1), which has nothing
to overlap with on one unit.

## 5. Option C: two permutation units

**Idea.** Elephant is a parallel mode. Masks depend only on the key and the block index, and the
keystream and MAC permutations of different blocks don't depend on each other's data. Run two
`elephant_perm` instances side by side.

**Which pairing to use.** The mask LFSR window at position a holds prev = φ^(a-1), cur = φ^a and
next = φ^(a+1). It advances one step per block. Pairing **keystream(k+1) with MAC(k)** needs no LFSR
change:

| Job | v2 mask | Window at a = k+1 |
|---|---|---|
| keystream(k) (current) | φ^k ⊕ φ^(k+1) | prev ⊕ cur |
| **keystream(k+1)** | φ^(k+1) ⊕ φ^(k+2) | **cur ⊕ next** (new mux leg) |
| **MAC(k)** | φ^k ⊕ φ^(k+2) | **prev ⊕ next** (existing) |
| AD block j | φ^j | prev (at a = j+1) |
| **AD block j+1** | φ^(j+1) | **cur** (new mux leg) |

**Encryption schedule.**
1. Prologue: keystream(0) alone (prev ⊕ cur at a = 1). Then stream block 0, which leaves C(0) in the
   data register.
2. Steady state at a = k+1: unit A runs MAC(k) on C(k), and unit B runs keystream(k+1) on the nonce, both
   at the same time. Then stream block k+1 using unit B's result, accumulate unit A's result into the tag,
   and step the LFSR.
3. Epilogue: the last MAC alone (v2 sometimes has one more MAC block than keystream blocks), then the
   final tag permutation.

Decryption can use the same schedule. (The spec would also allow keystream(k) together with MAC(k), but
the streaming interface needs keystream(k) before it can output plaintext k, so the same pairing fits.)

**AD.** AD blocks can run two at a time (prev and cur masks), but both blocks must be loaded first. That
needs a second 160-bit input buffer, and the tag update becomes `tag ⊕ A ⊕ B`. Running AD at the same
time as the message is harder: the AD and the message both use the single mask LFSR, which is reloaded in
`MDATA_NPUB`. It would need a second `elephant_datapath_lfsr` instance (176 FF). Leave that for later.

**Files and changes**
- `elephant_datapath.vhd`
  - Add a second `entity work.elephant_perm` instance (`PERM_B`) and a second state register `msb_reg`
    with its own input mux (a cur ⊕ next leg for keystream(k+1), a cur leg for AD j+1).
  - `tag_input` takes both unit outputs during AD pairs.
  - `ms_out_mux2` reads the keystream from `msb_reg`.
  - If both units run in lockstep they use the same round constants every cycle, so they can share
    `perm_count`. Optionally move the ROM out of `elephant_perm` so it isn't duplicated (check whether
    Vivado already merges it).
- `elephant_datapath_lfsr.vhd`: no change for this pairing. The window is a byte-wise shift register, so
  each extra mask of lookahead costs only 8 FF (176 → 184 bits) plus one more step in the load sequence.
  You'd need that if you pair blocks further apart.
- `CryptoCore.vhd`: new prologue, steady-state and epilogue states for the message, and an "AD pair" path.
  Ports for a second `perm_en`/`ms_en`, or a shared enable when the units run in lockstep.
- `profile.txt`: one probe per unit, for example `perm_a perm_en` and `perm_b perm_b_en`. The profile then
  reports how often both units are busy at once.

**Gain.** Two permutations per 8 cycles: about 27 → 19 cycles per block on its own, and about 10–12 with
option B, where it approaches max(8 permutation cycles, about 6 I/O cycles) plus control. Area goes up by
roughly one more permutation's worth of LUTs, so throughput per LUT improves less than raw throughput.

**As built, combined with B ([brody/r4_BtoC/](brody/r4_BtoC/README.md)).** Pairing KS(k+1) with MAC(k)
would make streaming wait for KS(k+1), which undoes B. Instead, unit A runs MAC(k) while unit B runs KS(k+2), and
block k+1 streams from KS(k+1), computed one round earlier. That needs φ^k, φ^(k+2) and φ^(k+3) at once, so the
LFSR window grew by one mask (next2, 176 → 184 bits).

AD pairs are set up with next/next2. The LFSR steps once mid-permutation, so the POST unmask uses cur/next and the
window advances two per pair.

Measured at R = 4:
- **Cycles:** 21.74 per PT block (r4_B 42.81) and 11.19 per AD block (r4_B 22.06).
- **Area:** +854 LUT and +329 FF over r4_B.
- **Fmax:** 184.3 → 169.5 MHz. The new critical path is control fanout into the 160-bit muxes.

## 6. Option D: pipeline the permutation and interleave two calls

**Idea.** Split the existing R-round combinational chain into two stages with a 160-bit register between
them (for example 5 + 5 rounds at R = 10). The critical path roughly halves, so Fmax roughly doubles. Each
permutation now takes 16 cycles, but two independent calls are in flight at once (one in each stage). They
are the same pairs as in C: {MAC(k), keystream(k+1)} or {AD j, AD j+1}. This gives about C's throughput
with **one permutation's worth of round logic**, so it scores better on throughput per LUT.

**Files and changes**
- `elephant_perm.vhd`
  - Add a generic or constant `PERM_STAGES` and a register after round R/STAGES.
  - Round constants: each stage handles a different slice of the 80 rounds in a given cycle. Index the
    constants per stage. With 5 + 5 and the existing `lfsr_rom5`, stage 1 uses entry 2l and stage 2 uses
    entry 2l+1 on lap l, or each stage gets its own counter.
  - The port gains a stage-valid or phase input. `load_lfsr` (used only for R = 1) can stay as it is.
- `elephant_datapath.vhd`: the loop becomes `ms_reg → stage 1 → pipe_reg → stage 2 → ms_reg`.
  - Load call A into `ms_reg`, and a cycle later call B (it needs a mux on the `ms_reg` input).
  - Both results come out of stage 2 on alternating cycles, so one of them needs a holding register (same
    role as `msb_reg` in C).
  - Same mask legs and tag changes as C.
- `CryptoCore.vhd`: same schedule as C. `PERM` counts `2 × PERM_CYCLES` with an A/B phase bit. Calls that
  can't be paired (key setup, the final tag permutation, an odd AD block) take 2× the cycles at about 2×
  the clock, so about the same wall time.
- `profile.txt`: a probe that is '1' while any call is in flight. Add per-call probes if you want to see
  how well the pipeline is used.

**Watch out for:** once the permutation is split, the critical path may move to the FSM, the mask muxes
or the LWC wrapper. Check the Vivado timing report before adding more stages.

## 7. Option E: stagger the calls

**Idea.** In r4_BtoD the 4 in-flight calls move in lockstep: a batch loads together, runs 20 cycles
together and unloads together. So a batch waits for its slowest input, every batch pays setup and unmask
cycles, and slots sit idle between batches. In E every stage register carries its own call, with its own
round counter, so each call starts as soon as its input is ready and finishes 20 cycles later on its own.
The hardware shape is the same as r4_BtoD (2 units × 2 stages × 4 rounds).

**Files and changes** (details in [brody/r4_BtoE/README.md](brody/r4_BtoE/README.md))
- `elephant_datapath.vhd`
  - One shared load path `x = src ⊕ mask`, chosen by the call kind, replaces r4_BtoD's four slot muxes. At
    most one call starts per cycle.
  - Each register's round index `pc(p)` moves through the ring with its call.
  - A 4-entry mask store keeps each call's mask for unmasking at the end.
  - A finished call's output and mask are registered. The next cycle the result goes to the key, the
    tag (one XOR per cycle) or the keystream FIFO.
  - Two input buffers: the loader fills one while the other waits to be called.
  - A 3-deep keystream FIFO. Keystream calls need only N and L, so they run up to 3 blocks ahead of the
    message, starting during AD.
- `elephant_datapath_lfsr.vhd`: a generic `elephant_mask_lfsr`, instantiated twice (AD/MAC window, 3 masks;
  keystream window, 2 masks), so MAC and keystream can be at different block indices.
- `CryptoCore.vhd`: an issue engine, one cycle ahead, picks a register whose call is gone next cycle
  and the oldest request: KEY > FIN > next full input buffer (AD or MAC, in block order) > keystream.
  - Segment detection waits on `bdi_type` (with a `SEG_WAIT` timeout), because AD and the message now
    start right after the nonce.

**Result.**
- **Cycles:** 9.88 per PT block (r4_BtoD 10.87) and 6.02 per AD block (r4_BtoD 6.50); 1536 B PT 931 → 848.
- **Area:** 5639 LUT, 3421 FF (+907 LUT, +1018 FF over r4_BtoD).
- **Fmax:** 147.8 → 163.8 MHz, because r4_BtoD's batch_done → loader handshake path is gone.
- **Throughput:** 2652 Mbps long PT, 470 Kbps/LUT.
- **Critical path:** three paths within 1.4%: stage register → 4 rounds → 4:1 result mux; keystream FIFO →
  `bdo` → PostProcessor; issue → shared `x` → stage register.

**Watch out for:** PT is now slot-bound: 2 calls per block × 20 cycles / 4 slots = 10 cycles per block.
Only more slots (units or stages) or a faster clock cut it further. With staggering, adding slots no
longer needs a wider batch or a wider tag XOR.

## 8. Option F: fast loader

**Idea.** The loader spent a decision cycle after each block (`data_cnt = BLOCK_SIZE`) to mark the buffer
full, pop the keystream and switch buffers, so a 5-word block took 6 cycles. F does all of that in the
cycle the last word goes in, and starts the next block the cycle after if the other buffer is free. It is
the same idea as `G_FAST_LOADER` in [brody/gen](brody/gen/README.md), applied to E's two-buffer loader.

**Files and changes** (details in [brody/r4_BtoF/README.md](brody/r4_BtoF/README.md))
- `CryptoCore.vhd` only. The loader works out the block's end state in variables in the last word's cycle.
  - Block 0 (N‖AD0) initializes the tag from buffer 0 while that buffer still takes its last word, so
    the tag initialization is delayed one cycle (`tag_init_d`).
  - If the other buffer is busy, the loader waits at `data_cnt = BLOCK_SIZE+1`.

**Result.**
- **Cycles:** 5.01 per AD block (the 32-bit bus limit of 5); PT stays at 9.88 (slot-bound).
  `make profile WL=long` 2616 → 2476 cycles, with all four registers busy 91.2% of the time.
- **Area:** 5631 LUT, 3430 FF, about the same as E.
- **Fmax:** 162.4 MHz, same critical path as E.
- **Throughput:** 5182 Mbps long AD (×1.19 vs E), 2629 Mbps long PT, 467 Kbps/LUT.

**Watch out for:** the first `make synth` search stopped at 143.3 MHz from Vivado run-to-run noise.
Re-running with `PERIOD0=6.2` closed at 6.162 ns. Check the run list in `reports/synth_runs.csv` when
a result looks out of line.

## 9. Option G: more slots and shorter control paths

**Idea.** After F, plaintext was bound by the slots: 2 calls per block × 20 cycles / 4 slots = 10 cycles
per block. With staggered calls, cycles per block ≈ 160 / (rounds computed per cycle over all units), so
doubling the round hardware (4 units × 2 stages × 4 rounds = 32 rounds per cycle) brings plaintext to 5,
the bus limit. To keep the clock, G also shortens the three paths that tied in r4_BtoF.

**Files and changes** (details in [brody/r4_BtoG/README.md](brody/r4_BtoG/README.md))
- `elephant_constants.vhd`: `NUNIT`, `NSTAGE` (generic rings: `nxt`, `prv`, `vslot`), `NKS` = 6, and a
  round-constant table `RC_TAB` generated from the Spongent LFSR for any rounds per stage.
- `elephant_perm.vhd`: takes the round constants as a registered input instead of a round counter.
- `elephant_datapath.vhd`
  - `x = src ⊕ mask` and the mask are registered (`xr`, `mr`) before they go into a stage register and
    the mask store.
  - The result is selected by a binary index.
  - The keystream head shifts one word per message word, so `bdo` needs no `data_count` mux. The rest of
    the FIFO is a circular store.
- `CryptoCore.vhd`
  - The issue engine decides two cycles ahead (stage A prepares `xr`, stage B loads it). Its
    free-register test looks two cycles ahead and accounts for both pending calls.
  - Per-register round constants are registered next to the round counters.

**Result.**
- **Cycles:** 4.93 per PT block (r4_BtoF 9.86) and 5.00 per AD block; 1536 B PT 847 → 470. Short
  messages pay 2–3 cycles for the extra issue stage (16 B: 87 → 90).
- **Keystream depth:** NKS = 6 is needed to reach 5 cycles per block (NKS 3/4/5: 9.9/7.5/5.9).
- **Area:** 7295 LUT, 4841 FF (+1664 LUT, +1411 FF over r4_BtoF).
- **Fmax:** 161.2 MHz.
- **Throughput:** 5219 Mbps long PT (×1.99 vs r4_BtoF), 715 Kbps/LUT (×1.53).
- **Critical path:** stage register → 4 rounds → 8:1 result mux. The ring itself and the frozen wrapper
  are within 0.13 ns of it, so about 170 MHz is the floor at 4 rounds per stage.

**Watch out for:**
- Vivado noise in the Fmax search: one search started at 6.0 ns fell back to 145 MHz. Re-running at the
  met period reproduces 161.2 MHz exactly.
- LUT count moves with the target period, from 6183 to 8312 LUT.

## 10. Option H: the same cycles in less area

**Idea.** G is at the bus limit, so the remaining gains are area and clock. In G, a new call could go into
any stage register, which costs a load mux in front of every stage register, an 8:1 result mux and an
indexed mask store with its own 8:1 read mux: about 2100 LUT and 1280 FF that aren't rounds. If the call
count per ring divides evenly (`PERM_CYCLES mod NSTAGE = 0`), a call loaded into stage 0 always finishes in
the last stage and frees its slot back to stage 0, so loading only into stage 0 costs no cycles.

**Files and changes** (details in [brody/r4_BtoH/README.md](brody/r4_BtoH/README.md))
- `elephant_constants.vhd`: 2 rings × 4 stages instead of 4 × 2 (fewer stage-0 load muxes, 2:1 result
  mux); `vslot` gone. 1 × 8 is not possible at 4 rounds per stage (20 mod 8 ≠ 0).
- `elephant_datapath.vhd`
  - Only stage 0 of each ring has a load mux; the result comes from a ring's last stage.
  - Calls finish in load order, so the masks go through a `PERM_CYCLES`-deep shift register (SRLs)
    instead of the mask store.
  - The keystream FIFO store writes on every push, so its write enable no longer depends on the
    wrapper handshake.
- `CryptoCore.vhd`: the issue engine only considers stage-0 registers; finish detection only looks at last
  stages; the ring phase `ph` and mask store writes are gone.

**Result.**
- **Cycles:** identical to G (4.93 per PT block, 5.00 per AD block, 16 B in 90).
- **Area:** 5496 LUT, 3370 FF (−25% LUT, −30% FF). The rounds take 2819 LUT sites (51%), close to the
  floor of 80 per round; the rest is mask, source and result logic, control and the wrapper.
- **Fmax:** 174.6 MHz (+8%): without the 8:1 result mux the round path has slack.
- **Throughput:** 5653 Mbps long PT, 1029 Kbps/LUT (G 715, ×1.44).
- **Critical path:** the frozen wrapper's PreProcessor FSM → loader handshake → `dp/ib`, `dp/kh`.

**Also tried: 2 rounds per stage** ([brody/r2_BtoH/](brody/r2_BtoH/README.md), 2 × 8
stages, NKS = 10). Same cycles per block, but 171.4 MHz, 5786 LUT, 4766 FF and 60 more cycles on short
messages (each dependent call takes 40 cycles). The wrapper path is the limit there too, so shorter stages
don't help.

## 11. Option I: the wrapper handshake off the critical path

**Idea.** H's worst path started in the frozen PreProcessor, but only its first LUT level was there: the
other six were our loader turning "a word is accepted" into the keystream head's enable, with two 160-wide
fanouts. Registering both handshakes takes the wrapper off every core path; building the head's next value
from registers leaves the accept as the last mux select.

**Files and changes** (details in [brody/r4_BtoI/README.md](brody/r4_BtoI/README.md))
- `CryptoCore.vhd`
  - 2-entry register slice on `bdi` (word, valid bytes, size, eot, type, decrypt flag): `bdi_ready` is a
    flip-flop, the loader decides on a registered word.
  - 2-entry register slice on `bdo` (word, valid bytes, type, end of block): `bdo_valid` is a flip-flop, the
    loader's "output has room" is a flip-flop.
  - Segment check on the slice's head word; while the slice is empty it peeks at the wrapper's `bdi_type`
    for the empty-segment decision only.
- `elephant_datapath.vhd`: `kh_pop` / `kh_keep` candidates from registers; `ks_pop` / `ks_adv` select last.

**Result.**
- **Cycles:** per block unchanged (4.94 PT); +1–2 cycles per message for the slices (16 B 92, 1536 B 472);
  the long workload is 4 cycles faster (1683 vs 1687).
- **Area:** 5467 LUT, 3536 FF (+166 FF for the slices).
- **Fmax:** 182.5 MHz (+4.5%). The rounds are now the critical path (5–6 levels, about 73% routing).
- **Throughput:** 5909 Mbps long PT, 1081 Kbps/LUT (H 1029); 16 B PT 254 Mbps (H 248).

**At 2 rounds per stage** ([attic/brody/r2_BtoI/](attic/brody/r2_BtoI/README.md)): 201.4 MHz
(r2 H 171.4), 5852 LUT, 4933 FF, 6521 Mbps long PT, 1114 Kbps/LUT. Its critical path is now inside the
frozen wrapper (PreProcessor FSM → PostProcessor FSM), so this is about as fast as the wrapper allows. It
loses to I at 4 rounds per stage on every message up to at least 1536 B (16 B: 152 vs 92 cycles).

## 12. Option J: a smaller source and mask select

**Idea.** After I, the largest non-round logic is the input of each new call, `x = source ⊕ mask`: 802 LUT
cells, about 5 per state bit, because the datapath decoded the call's kind into a 3-way source and a 5-way
mask select. Every mask is the XOR of one term from {0, φ^k, keystream φ^k, L} and one from
{0, φ^(k+2), φ^(k+1)}, so three 4:1 muxes on 2-bit selects do the same job in about 4 LUTs per bit.

**Files and changes** (details in [brody/r4_BtoJ/README.md](brody/r4_BtoJ/README.md))
- `CryptoCore.vhd`: the issue decision registers `iss_src`, `iss_ma`, `iss_mb` with the call's kind.
- `elephant_datapath.vhd`: source, A and B as `with … select` muxes; `mask = A ⊕ B`, `x = source ⊕ mask`.

**Result.** Same cycles and clock (182.4 MHz). Source / mask logic 640 LUT cells instead of 802; 5396 LUT
(−71, −1.3%, about the size of Vivado's run-to-run LUT spread); 1094 Kbps/LUT. At 2 rounds per stage: 5767 LUT (−85) at 197.6 MHz (r2 I: 201.4 MHz; the wrapper-bound clock varies by a few percent between searches), 1109 Kbps/LUT.

**Tool flows** (same RTL as I; see the "Tool flow study" in
[brody/r4_BtoI/README.md](brody/r4_BtoI/README.md)): timing-driven synthesis
and timing directives reach 191.2 MHz but with +17% LUTs (969 Kbps/LUT); area directives reach 5100 LUT at
169.8 MHz (1078 Kbps/LUT). Neither beats the standard flow on throughput per LUT, so all results use it.

## 13. Recommended order

1. **A (sweep R)** first. It is nearly free, gives the Fmax/area/throughput curve, and shows whether the
   permutation is the critical path at all. Pick the best R for each metric as the base for later cores.
2. **Unit testbench for `elephant_perm`** (`tb/unit/`, still to do) before touching permutation internals
   (A with new ROMs, D). It is much faster to debug round-constant indexing there than through `LWC_TB`.
3. **C or D** next, built on the {MAC(k), keystream(k+1)} schedule. C is simpler to get right. D is
   better on throughput per LUT. Both need the same FSM rework, so do the schedule once and then try both
   datapaths.
4. **B on top of C or D.** After the permutation cycles are cut, I/O and control overhead is most of each
   block, and this is where the remaining gain is.

   *Update:* B was built first, as `brody/r4_B`. For C or D, start from that core: its loader and
   KS(k+1)/MAC(k) schedule are exactly the pairing C and D need. A second unit would run KS(k+1) at the same
   time as MAC(k) instead of before it.
5. **E, then F, on top of B + C + D.** Once there are several slots, lockstep batches waste them; staggering
   fills them, and the fast loader then brings AD to the bus limit. After F, PT is slot-bound, so the next
   lever is more slots (U or S), which the sweep explores.
6. **G: double the slots** and take the control paths off the critical path. Both PT and AD are then at
   the 32-bit bus limit; what's left is short-message latency and area.
7. **H: load only into stage 0** to remove G's load and result muxes and mask store. Same cycles, −25% LUT,
   +8% clock. After H the clock is set by the frozen wrapper's handshake, so fewer rounds per stage don't
   help (measured at 2 rounds per stage).
8. **I: register the wrapper handshakes** (one cycle each way per message). The rounds then set the clock
   at 4 rounds per stage (+4.5%), and 2 rounds per stage reaches the wrapper's own limit (201 MHz) at the
   cost of slower short messages.
9. **J: re-encode the source and mask select.** Area only, −1.3%. After J, the logic outside the rounds is
   one or two LUTs per state bit for functions the algorithm needs, and the rounds are within about 6% of
   their packing floor.

Every variant goes in its own directory, named as in [README.md](README.md) (copy `brody/base_r10`, fix `filelist.txt`,
keep the entity name `CryptoCore`). Then run `make sim-all`, `make cycles`, `make profile WL=long|short`, `make synth`
and `make report`, as described in the README's Benchmarking section.
