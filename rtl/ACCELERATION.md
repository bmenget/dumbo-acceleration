# Speeding up core_v2: options and where they land in the RTL

This is a plan for the optimized cores (`rtl/core_v2_opt*`). It covers four ways to make Dumbo v2 faster,
which files each one changes, and how. Line references are to `core_v2` as of 2026-11-19.
Background on the algorithm is in [../DUMBO_V2.md](../DUMBO_V2.md). The v1→v2 port is described in
[core_v2/V2_PORT.md](core_v2/V2_PORT.md).

**Status (2026-11-19)**

| Option | State |
|---|---|
| A | Swept: `core_v2_r1`, `r4`, `r5`, `r8`, `r16` (see `reports/benchmark.csv`) |
| B | **Done:** [core_v2_r4_optB/](core_v2_r4_optB/OPT_B.md), on top of `core_v2_r4`. Section 4 describes how it was built. |
| C | Not started |
| D | Not started |

## 1. Where the time goes today

**RTL map** (only `core_v2_opt*/` gets edited; `lwc/` and `core_v1/` are frozen):

```
LWC (lwc/LWC.vhd, frozen) ── PreProcessor / PostProcessor / header FIFO
└─ CryptoCore            core_v2/CryptoCore.vhd           control FSM, perm_cnt_int, data_cnt_int
   └─ elephant_datapath  core_v2/elephant_datapath.vhd    ms_reg (state), tag_out, load_data_output, mask muxes
      ├─ elephant_perm          core_v2/elephant_perm.vhd          Spongent-π[160], combinational
      └─ elephant_datapath_lfsr core_v2/elephant_datapath_lfsr.vhd mask window φ^(a-1), φ^a, φ^(a+1)
```

**The permutation loop:** `ms_reg → elephant_perm (PERM_ROUNDS_PER_CYCLE rounds) → ms_reg`
([elephant_datapath.vhd:200-201](core_v2/elephant_datapath.vhd#L200-L201)). With the current
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

**Which files each option touches** (✎ = edit, · = unchanged):

| File | A | B | C | D |
|---|---|---|---|---|
| `elephant_constants.vhd` | ✎ R value | · | · | ✎ stage count |
| `elephant_perm.vhd` | ✎ only for R ∉ {1,4,5,8,10,16} | · | · (instantiated twice) | ✎ pipeline register, per-stage constants |
| `elephant_datapath.vhd` | · | ✎ keystream buffer, cur ⊕ next mask, nonce source | ✎ second unit, second state register, masks, tag XOR | ✎ second holding register, muxes |
| `elephant_datapath_lfsr.vhd` | · | · | · (possibly +8 FF, see C) | · |
| `CryptoCore.vhd` | · | ✎ schedule | ✎ schedule | ✎ schedule |
| `profile.txt` | · | · | ✎ one probe per unit | ✎ probe per in-flight call |
| `filelist.txt` | ✎ path rename when copying the core | same | same | same |

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

**As built ([core_v2_r4_optB/](core_v2_r4_optB/OPT_B.md)).** It follows the plan above, with these differences:
- **Keystream mask.** KS(k+1) needs cur ⊕ next, a mask leg `core_v2` doesn't have. The 6-way select became
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

Measured at R = 4 against `core_v2_r4`:
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

## 7. Recommended order

1. **A (sweep R)** first. It is nearly free, gives the Fmax/area/throughput curve, and shows whether the
   permutation is the critical path at all. Pick the best R for each metric as the base for later cores.
2. **Unit testbench for `elephant_perm`** (`tb/unit/`, still to do) before touching permutation internals
   (A with new ROMs, D). It is much faster to debug round-constant indexing there than through `LWC_TB`.
3. **C or D** next, built on the {MAC(k), keystream(k+1)} schedule. C is simpler to get right. D is
   better on throughput per LUT. Both need the same FSM rework, so do the schedule once and then try both
   datapaths.
4. **B on top of C or D.** After the permutation cycles are cut, I/O and control overhead is most of each
   block, and this is where the remaining gain is.

   *Update:* B was built first, as `core_v2_r4_optB`. For C or D, start from that core: its loader and
   KS(k+1)/MAC(k) schedule are exactly the pairing C and D need. A second unit would run KS(k+1) at the same
   time as MAC(k) instead of before it.

Every variant goes in its own `rtl/core_v2_optN/` (copy `core_v2`, fix `filelist.txt`, keep the entity
name `CryptoCore`). Then run `make sim-all`, `make cycles`, `make profile WL=long|short`, `make synth`
and `make report`, as described in the README's Benchmarking section.
