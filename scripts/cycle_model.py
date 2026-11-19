#!/usr/bin/env python3
"""Cycle model of core_v2 (Dumbo v2, GMU arch-1 style serial core) behind the LWC wrapper, 32-bit I/O.

Measured quantity: the testbench's "Actual Execution Time" (LWC_TB, G_TEST_MODE=4): clock cycles from
the first PDI word accepted until the final status/tag word leaves the wrapper.

Algorithm (Elephant v2 spec, Algorithm 1), n = 160-bit blocks = 20 bytes:
    lA = floor((12 + |AD|) / 20) + 1     blocks of N||AD||1       (first block is NOT permuted in v2)
    lM = ceil(|M| / 20)                   keystream blocks
    lC = floor(|M| / 20) + 1              blocks of C||1 for the MAC
    permutations in the spec = (lA - 1) + lM + lC + 1      (+1 for L = P(K||0) on a new key)

What the RTL does (rtl/core_v2/CryptoCore.vhd), strictly one permutation at a time, no overlap of
I/O with the permutation, so the spec's parallelism is unused:
    - an empty message still runs one keystream permutation (nK = max(lM, 1)); this is a wasted
      permutation (the C model has none), see CryptoCore POST_PERM / MDATA_NPUB
    - decrypt costs exactly the same as encrypt
    - new key: one more permutation (PERM_KEY) plus 4 key-word cycles

    cycles = perms * PC  +  c_fixed + c_ad*nAD + c_ks*nK + c_mac*nC + c_key*new_key
    perms  = nAD + nK + nC + 1 + new_key,   PC = 80 / PERM_ROUNDS_PER_CYCLE  (cycles per permutation)

The coefficients were fitted to simulation and then checked: `--validate` compares the model with
every build/sim/questa/v2*/cycles/timing.csv (produced by `make cycles`); the fit is exact (max error
0 cycles) over 75 vectors x ROUNDS in {1, 4, 5, 8, 10, 16}.

Usage:
    python3 scripts/cycle_model.py --validate                 # model vs simulation
    python3 scripts/cycle_model.py --table                    # cycles for the standard workloads
    python3 scripts/cycle_model.py --from-results             # reports/synth_results.csv -> reports/perf_model.csv
"""
import argparse
import csv
import datetime
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SYNTH_RESULTS = ROOT / "reports" / "synth_results.csv"
PERF_CSV = ROOT / "reports" / "perf_model.csv"

BLOCK = 20          # bytes per Elephant block (n = 160 bits)
NPUB = 12           # bytes of nonce, prepended to the AD
PERM_ROUNDS = 80    # Spongent-pi[160]

# Non-permutation cycles per phase. PRE_PERM + POST_PERM (1 cycle each) are inside every one of these.
C_AD = 8      # AD block: 5 words in + 1 pad/transition + PRE + POST
C_MAC = 8     # ciphertext block: same shape as an AD block
C_KS = 3      # keystream: MDATA_NPUB + PRE + POST (the nonce block needs no input words)
C_KEY = 4     # new key: 4 key words (the key permutation itself is counted in `perms`)
C_FIXED = 18  # npub/first-block load, tag out, wrapper latency, and the final permutation's PRE+POST

# Workloads reported in the CSV: (label, AD bytes, message bytes, new_key)
WORKLOADS = [
    ("16B-AD+16B-msg", 16, 16, False),    # NIST LWC software benchmark point
    ("16B-AD+16B-msg-newkey", 16, 16, True),
    ("64B-AD+64B-msg", 64, 64, False),    # eBACS short
    ("0B-AD+1536B-msg", 0, 1536, False),  # long-message throughput
    ("1536B-AD+0B-msg", 1536, 0, False),  # AD-only throughput
    ("1536B-AD+1536B-msg", 1536, 1536, False),  # eBACS/NIST long
]


def blocks(ad, msg):
    """(lA, lM, lC) per the spec."""
    return (NPUB + ad) // BLOCK + 1, -(-msg // BLOCK), msg // BLOCK + 1


def spec_perms(ad, msg, new_key=False):
    """Permutations the algorithm needs (the C model's count), incl. L = P(K||0) when the key is new."""
    lA, lM, lC = blocks(ad, msg)
    return (lA - 1) + lM + lC + 1 + int(new_key)


def hw_perms(ad, msg, new_key=False):
    """Permutations core_v2 actually runs (one extra keystream permutation when msg is empty)."""
    lA, lM, lC = blocks(ad, msg)
    return (lA - 1) + max(lM, 1) + lC + 1 + int(new_key)


def cycles(rounds, ad, msg, new_key=False):
    """Execution time in clock cycles for PERM_ROUNDS_PER_CYCLE = rounds."""
    if PERM_ROUNDS % rounds:
        raise ValueError(f"rounds={rounds} does not divide {PERM_ROUNDS}")
    pc = PERM_ROUNDS // rounds
    lA, lM, lC = blocks(ad, msg)
    n_ad, n_ks, n_mac = lA - 1, max(lM, 1), lC
    return (hw_perms(ad, msg, new_key) * pc + C_FIXED + C_AD * n_ad + C_KS * n_ks
            + C_MAC * n_mac + C_KEY * int(new_key))


def perf_row(res, label, ad, msg, new_key):
    """One CSV row: a synthesized design point (a synth_results.csv row) x one workload."""
    rounds = int(res["rounds"])
    cyc = cycles(rounds, ad, msg, new_key)
    pc = PERM_ROUNDS // rounds
    perms = hw_perms(ad, msg, new_key)
    fmax = float(res["fmax_mhz"])
    t_us = cyc / fmax                                  # cycles / MHz = microseconds
    data = ad + msg
    return {
        "date": res.get("date", ""), "spec": res["spec"], "rounds": rounds, "perm_cycles": pc,
        "fmax_mhz": res["fmax_mhz"], "closed": res.get("closed", ""),
        "luts": res["luts"], "ffs": res["ffs"], "slices": res["slices"],
        "workload": label, "ad_bytes": ad, "msg_bytes": msg, "new_key": int(new_key),
        "perms_spec": spec_perms(ad, msg, new_key), "perms_hw": perms,
        "cycles": cyc, "perm_cycles_total": perms * pc,
        "perm_share": f"{perms * pc / cyc:.3f}",
        "cycles_per_byte": f"{cyc / data:.2f}" if data else "",
        "latency_us": f"{t_us:.3f}",
        "throughput_mbps": f"{8 * data / t_us:.2f}" if data else "",
        "mbps_per_klut": f"{8 * data / t_us / (int(res['luts']) / 1000):.3f}" if data else "",
        "part": res.get("part", ""), "vivado": res.get("vivado", ""),
    }


PERF_COLS = ["date", "spec", "rounds", "perm_cycles", "fmax_mhz", "closed", "luts", "ffs", "slices",
             "workload", "ad_bytes", "msg_bytes", "new_key", "perms_spec", "perms_hw", "cycles",
             "perm_cycles_total", "perm_share", "cycles_per_byte", "latency_us", "throughput_mbps",
             "mbps_per_klut", "part", "vivado"]


def append_perf(res, path=PERF_CSV):
    """Append one row per workload for a synth_results.csv-style dict. Only core_v2 has a model."""
    if res["spec"] != "v2":
        print(f"[cycle_model] no cycle model for spec {res['spec']}; skipping {path.name}")
        return 0
    path.parent.mkdir(parents=True, exist_ok=True)
    new = not path.exists()
    with path.open("a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=PERF_COLS)
        if new:
            w.writeheader()
        for label, ad, msg, nk in WORKLOADS:
            w.writerow(perf_row(res, label, ad, msg, nk))
    return len(WORKLOADS)


def validate():
    """Compare the model with every simulated timing.csv. Exit status 1 on any mismatch."""
    sims = ROOT / "build" / "sim" / "questa"
    worst, n, files = 0, 0, 0
    for d in sorted(sims.glob("v2*/cycles/timing.csv")):
        m = re.fullmatch(r"v2(?:_r(\d+))?", d.parent.parent.name)
        rounds = int(m.group(1)) if m.group(1) else 10   # rtl/ default is PERM_ROUNDS_PER_CYCLE = 10
        files += 1
        for r in csv.DictReader(d.open()):
            got = int(r["Actual Execution Time"])
            want = cycles(rounds, int(r["AD Size"]), int(r["Msg Size"]), r["New Key"] == "1")
            worst = max(worst, abs(got - want))
            n += 1
            if got != want:
                print(f"MISMATCH rounds={rounds} msg={r['Msg ID']} ad={r['AD Size']} "
                      f"pt={r['Msg Size']} newkey={r['New Key']}: sim {got} model {want}")
    if not n:
        sys.exit("no timing.csv found: run `make cycles` first")
    print(f"validated {n} measurements from {files} configurations: max |error| = {worst} cycles")
    return worst


def table():
    print(f"{'workload':<24}{'perms spec':>11}{'perms hw':>9}" + "".join(f"{'R=' + str(r):>9}" for r in (1, 4, 8, 10, 16)))
    for label, ad, msg, nk in WORKLOADS:
        print(f"{label:<24}{spec_perms(ad, msg, nk):>11}{hw_perms(ad, msg, nk):>9}"
              + "".join(f"{cycles(r, ad, msg, nk):>9}" for r in (1, 4, 8, 10, 16)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--validate", action="store_true")
    ap.add_argument("--table", action="store_true")
    ap.add_argument("--from-results", action="store_true",
                    help="rebuild reports/perf_model.csv from reports/synth_results.csv (no Vivado run)")
    a = ap.parse_args()
    if a.validate:
        sys.exit(1 if validate() else 0)
    if a.table:
        table()
    if a.from_results:
        PERF_CSV.unlink(missing_ok=True)
        rows = [r for r in csv.DictReader(SYNTH_RESULTS.open())]
        n = sum(append_perf(r) for r in rows)
        print(f"wrote {n} rows ({len(rows)} design points) to {PERF_CSV.relative_to(ROOT)}")
    if not (a.validate or a.table or a.from_results):
        ap.print_help()


if __name__ == "__main__":
    main()
