#!/usr/bin/env python3
"""Cycle profile of a core: where do the clock cycles go?

`make profile CORE=<core> WL=<short|long>` runs the prof_<WL> vector set (encrypt with a new key, then
decrypt with the same key) with Questa dumping a VCD of:
  - the clock and the core's data handshakes (CryptoCore ports, the same for every core):
      in  = bdi_valid and bdi_ready, or key_valid and key_ready   (a 32-bit word enters the core)
      out = bdo_valid and bdo_ready                               (a 32-bit word leaves the core)
  - the core's "busy" probes, listed in rtl/core_<core>/profile.txt, one per line:
        <label>  <path below the CryptoCore instance>
    e.g.  perm  perm_en
    Each probe must be a std_logic that is '1' exactly in the cycles a permutation unit computes rounds.
    A core with two permutation units lists two probes.

Every rising clock edge is one cycle, classified as:
  busy+io   a permutation unit is busy AND a word moves in or out   (overlap: the goal)
  busy      a permutation unit is busy, no I/O
  io        I/O only, no unit busy
  neither   control/wait cycles: no unit busy and no word moves
The window runs from the first to the last cycle with any activity (busy or I/O), so it includes the
final tag permutation and the tag check of a decryption.

Subcommands (both called by the Makefile):
  profile.py do    --core v2 --out build/prof/v2.do          write the Questa do-file
  profile.py parse --core v2 --workload long --vcd <file>    classify cycles, print, update reports/profile.csv
"""
import argparse
import csv
import datetime
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROFILE_CSV = ROOT / "reports" / "profile.csv"
INST = "/LWC_TB/uut/Inst_Cipher"          # CryptoCore instance inside the LWC wrapper
CLK = "/LWC_TB/uut/clk"
IO = {"in_valid": "bdi_valid", "in_ready": "bdi_ready", "key_valid": "key_valid", "key_ready": "key_ready",
      "out_valid": "bdo_valid", "out_ready": "bdo_ready"}
COLS = ["date", "core", "workload", "window_cycles", "busy_io_pct", "busy_pct", "io_pct", "neither_pct",
        "any_busy_pct", "unit_busy", "units_concurrent", "in_words", "out_words"]


def probes(core):
    f = ROOT / "rtl" / f"core_{core}" / "profile.txt"
    out = []
    for line in f.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            label, path = line.split()
            out.append((label, f"{INST}/{path.strip('/')}"))
    if not out:
        sys.exit(f"{f}: no probes listed")
    return out


def cmd_do(a):
    lines = ["vcd file prof.vcd", f"vcd add {CLK}"]
    lines += [f"vcd add {INST}/{sig}" for sig in IO.values()]
    lines += [f"vcd add {path}" for _, path in probes(a.core)]
    lines += ["run -all", "quit -f"]
    Path(a.out).write_text("\n".join(lines) + "\n")


def read_vcd(path, wanted):
    """Yield, for each rising clock edge, the values of `wanted` signals just before that edge.

    `wanted` maps a key to a full hierarchical path; matching is case-insensitive on the path.
    """
    ids, scope = {}, []
    want = {p.lower(): k for k, p in wanted.items()}
    f = open(path)
    for line in f:
        tok = line.split()
        if not tok:
            continue
        if tok[0] == "$scope":
            scope.append(tok[2])
        elif tok[0] == "$upscope":
            scope.pop()
        elif tok[0] == "$var":
            code, name = tok[3], tok[4]
            full = ("/" + "/".join(scope + [name])).lower()
            if full in want:
                ids.setdefault(code, []).append(want[full])
        elif tok[0] == "$enddefinitions":
            break
    found = {k for ks in ids.values() for k in ks}
    missing = set(wanted) - found
    if missing:
        sys.exit(f"signals not in the VCD: {', '.join(wanted[m] for m in sorted(missing))}\n"
                 f"(check the paths in profile.txt; the CryptoCore instance is {INST})")
    cur = {k: "x" for k in wanted}
    pending = []

    def flush():
        clk_rise = any(k == "clk" and v == "1" for k, v in pending) and cur["clk"] == "0"
        if clk_rise:
            yield dict(cur)          # values before this edge's updates = what the edge registers
        for k, v in pending:
            cur[k] = v

    for line in f:
        line = line.strip()
        if not line:
            continue
        if line[0] == "#":
            yield from flush()
            pending = []
        elif line[0] in "01xzXZ" and len(line) > 1:
            for k in ids.get(line[1:], ()):
                pending.append((k, line[0].lower()))
        elif line[0] in "bB":
            val, code = line[1:].split()
            for k in ids.get(code, ()):
                pending.append((k, val[-1].lower()))
    yield from flush()


def cmd_parse(a):
    pr = probes(a.core)
    wanted = {"clk": CLK, **{k: f"{INST}/{s}" for k, s in IO.items()}, **{l: p for l, p in pr}}
    labels = [l for l, _ in pr]
    rows = []
    for v in read_vcd(a.vcd, wanted):
        busy = [v[l] == "1" for l in labels]
        win = (v["in_valid"] == "1" and v["in_ready"] == "1") or (v["key_valid"] == "1" and v["key_ready"] == "1")
        wout = v["out_valid"] == "1" and v["out_ready"] == "1"
        rows.append((busy, win, wout))
    act = [i for i, (b, wi, wo) in enumerate(rows) if any(b) or wi or wo]
    if not act:
        sys.exit("no activity found in the VCD")
    rows = rows[act[0]: act[-1] + 1]
    n = len(rows)
    cat = {"busy+io": 0, "busy": 0, "io": 0, "neither": 0}
    unit = [0] * len(labels)
    conc = [0] * (len(labels) + 1)
    nin = nout = 0
    for busy, wi, wo in rows:
        b, io = any(busy), wi or wo
        cat["busy+io" if b and io else "busy" if b else "io" if io else "neither"] += 1
        for i, x in enumerate(busy):
            unit[i] += x
        conc[sum(busy)] += 1
        nin += wi
        nout += wo
    pct = lambda x: f"{100.0 * x / n:.1f}"

    print(f"\n=== profile: core_{a.core}, workload {a.workload} ({n} cycles in window) ===")
    for k in cat:
        print(f"  {k:<9}{cat[k]:>8}  {pct(cat[k]):>5}%")
    print(f"  any unit busy  {pct(n - conc[0])}%")
    for l, u in zip(labels, unit):
        print(f"  unit {l:<10} busy {u:>7} cycles ({pct(u)}%)")
    print(f"  units busy at once: " + ", ".join(f"{k}: {pct(c)}%" for k, c in enumerate(conc)))
    print(f"  words in {nin}, words out {nout}")

    row = dict(date=datetime.datetime.now().isoformat(timespec="seconds"), core=a.core,
               workload=a.workload, window_cycles=n, busy_io_pct=pct(cat["busy+io"]),
               busy_pct=pct(cat["busy"]), io_pct=pct(cat["io"]), neither_pct=pct(cat["neither"]),
               any_busy_pct=pct(n - conc[0]),
               unit_busy=" ".join(f"{l}={u}" for l, u in zip(labels, unit)),
               units_concurrent=" ".join(f"{k}:{pct(c)}%" for k, c in enumerate(conc)),
               in_words=nin, out_words=nout)
    old = []
    if PROFILE_CSV.exists():
        old = [r for r in csv.DictReader(PROFILE_CSV.open())
               if not (r["core"] == a.core and r["workload"] == a.workload)]
    PROFILE_CSV.parent.mkdir(parents=True, exist_ok=True)
    with PROFILE_CSV.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS)
        w.writeheader()
        for r in sorted(old + [row], key=lambda r: (r["core"], r["workload"])):
            w.writerow({c: r.get(c, "") for c in COLS})
    print(f"  -> {PROFILE_CSV.relative_to(ROOT)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("do")
    d.add_argument("--core", required=True)
    d.add_argument("--out", required=True)
    p = sub.add_parser("parse")
    p.add_argument("--core", required=True)
    p.add_argument("--workload", required=True)
    p.add_argument("--vcd", required=True)
    a = ap.parse_args()
    cmd_do(a) if a.cmd == "do" else cmd_parse(a)


if __name__ == "__main__":
    main()
