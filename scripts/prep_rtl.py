#!/usr/bin/env python3
"""Make a copy of the RTL for one design point and print its compile-ordered file list.

The sources under rtl/ are never edited. For a given spec and PERM_ROUNDS_PER_CYCLE this copies
rtl/lwc and rtl/core_<spec> into <out>/ and substitutes the constant in the copy's
elephant_constants.vhd. Both `make sim ROUNDS=N` and scripts/synth_sweep.py use it, so what is
simulated is exactly what is synthesized.

    prep_rtl.py --spec v2 --rounds 1 --out build/rtl/v2_r1   -> prints paths, one per line
        (relative to the project root unless --absolute)

Supported ROUNDS: 1, 4, 5, 8, 10, 16. elephant_perm.vhd only has round-constant tables for these
(1 uses a hardware LFSR). Other divisors of 80 (2, 20, 40, 80) compile but give wrong results: the
constant source is never driven. 10 is the value shipped upstream; GMU's docs list 1, 4, 5, 8.
Adding a value means adding its round-constant table to elephant_perm.vhd.
"""
import argparse
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONST = "elephant_constants.vhd"
PATTERN = re.compile(r"(constant\s+PERM_ROUNDS_PER_CYCLE\s*:\s*integer\s*:=\s*)(\d+)(\s*;)", re.I)


SUPPORTED = (1, 4, 5, 8, 10, 16)


def prep(spec, rounds, out):
    if rounds not in SUPPORTED:
        sys.exit(f"ROUNDS={rounds} is not supported by elephant_perm.vhd (supported: "
                 f"{', '.join(map(str, SUPPORTED))}); it has no round-constant table for it")
    core = ROOT / "rtl" / f"core_{spec}"
    flist = core / "filelist.txt"
    if not flist.exists():
        sys.exit(f"{flist} not found (SPEC must be v1 or v2)")
    out = Path(out)
    if not out.is_absolute():
        out = ROOT / out
    files = []
    for rel in flist.read_text().split():
        src = ROOT / rel
        dst = out / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        text = src.read_text()
        if src.name == CONST:
            text, n = PATTERN.subn(lambda m: f"{m.group(1)}{rounds}{m.group(3)}", text)
            if n != 1:
                sys.exit(f"expected exactly one PERM_ROUNDS_PER_CYCLE in {src}, found {n}")
        if not dst.exists() or dst.read_text() != text:  # keep mtimes stable for incremental tools
            dst.write_text(text)
        files.append(dst)
    return files


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spec", choices=("v1", "v2"), required=True)
    ap.add_argument("--rounds", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--absolute", action="store_true")
    a = ap.parse_args()
    for f in prep(a.spec, a.rounds, a.out):
        print(f if a.absolute else f.relative_to(ROOT))


if __name__ == "__main__":
    main()
