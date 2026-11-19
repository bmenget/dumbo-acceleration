#!/usr/bin/env python3
"""Generate LWC_TB test vectors (pdi/sdi/do.txt) from the C models in model/.

Same flow for both specs; only the C model differs:
    v1 -> model/crypto_aead/elephant160v1/ref   (Elephant v1, matches GMU RTL)
    v2 -> model/crypto_aead/elephant160v2/ref   (Dumbo v2, our target)

Output: kat/<spec>/gen/<set>/{pdi,sdi,do}.txt

Sets:
    random  random enc/dec, random key reuse, AD/PT 0..1000 B (like GMU's KATs)
    edge    every combination of AD and PT lengths around block boundaries,
            encrypt + decrypt
    full33  every (AD, PT) length pair 0..32 B, i.e. the 1089 combinations of the
            official KAT, each as encrypt (new key) + decrypt
    long    long messages (1536 B as in the LWC benchmarks, plus 4000 B)
    badtag  the decrypt vectors of `edge` with one tag bit flipped; expected
            status = failure
    cycles  a small (AD, PT) grid for cycle counting (`make cycles`): each pair as
            encrypt with a new key, encrypt reusing the key, and decrypt reusing the key
    prof_short, prof_long
            one workload each for `make profile`: encrypt (new key) + decrypt (same key)
            of 16 B AD + 16 B PT, and of 1536 B AD + 1536 B PT

cryptotvgen's --gen_custom flags must be 1/0: it reads the string "False" as true for NEW_KEY.

Run with the venv python:  .venv/bin/python scripts/gen_kat.py --spec v1
"""
import argparse
import random
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODEL = ROOT / "model"
LIB = MODEL / "lib"
ALGO = {"v1": "elephant160v1", "v2": "elephant160v2"}

# Same parameters as GMU's shipped KATs (see kat/v1/gmu/pdi.txt header).
COMMON = [
    "--candidates_dir", str(MODEL),  # never omit: without it cryptotvgen downloads SUPERCOP
    "--lib_path", str(LIB),
    "--io", "32", "32",
    "--key_size", "128", "--npub_size", "96", "--nsec_size", "0", "--tag_size", "64",
    "--block_size", "160", "--block_size_ad", "160",
    "--max_io_per_line", "8", "--max_block_per_sgmt", "9999",
    "--msg_format", "npub", "ad", "data", "tag",
]

# Block boundaries. Blocks are 20 B. The first AD block is Npub(12 B) || AD,
# so AD boundaries fall at 8, 28, 48 B; PT/CT boundaries at 20, 40, 60 B.
AD_LENS = [0, 1, 7, 8, 9, 19, 20, 21, 27, 28, 29, 39, 40, 41, 47, 48, 49]
PT_LENS = [0, 1, 19, 20, 21, 39, 40, 41, 59, 60, 61]
LONG = [(0, 1536), (1536, 0), (1536, 1536), (0, 4000), (4000, 4000)]
# `cycles` set: spans the block-count regimes (empty, partial, exact, many blocks) in AD and PT.
CYC_AD = [0, 8, 28, 160, 1536]
CYC_PT = [0, 1, 20, 160, 1536]
CYC_EXTRA = [(16, 16), (64, 64)]   # NIST LWC benchmark point and eBACS short point
PROF = {"prof_short": (16, 16), "prof_long": (1536, 1536)}


def custom_spec(pairs):
    """Encrypt with a new key, then decrypt with the same key (tests key reuse)."""
    vecs = []
    for ad, pt in pairs:
        vecs.append(f"1,0,{ad},{pt},0")
        vecs.append(f"0,1,{ad},{pt},0")
    return ":".join(vecs)


def cycles_spec(pairs):
    """Per pair: encrypt (new key), encrypt (same key), decrypt (same key)."""
    vecs = []
    for ad, pt in pairs:
        vecs += [f"1,0,{ad},{pt},0", f"0,0,{ad},{pt},0", f"0,1,{ad},{pt},0"]
    return ":".join(vecs)


def run_cryptotvgen(args, dest, seed):
    from cryptotvgen import cli  # imported here so --help works without the venv

    dest.mkdir(parents=True, exist_ok=True)
    random.seed(seed)  # cryptotvgen uses the global `random` module, unseeded
    rc = cli.run_cryptotvgen(COMMON + args + ["--dest", str(dest)],
                             logfile=str(dest / "cryptotvgen.log"))
    if rc not in (0, None):
        sys.exit(f"cryptotvgen failed for {dest} (rc={rc})")


def split_msgs(text):
    """Split a pdi/do file into (header, {msgid: block}) on '#### MsgID=' lines.

    Each block starts at the '#### Authenticated ...' line preceding the MsgID line.
    """
    lines = text.splitlines(keepends=True)
    starts = [i for i, l in enumerate(lines) if l.startswith("#### MsgID=")]
    # Include the operation line ("#### Authenticated Decryption") if present.
    starts = [i - 1 if i > 0 and lines[i - 1].startswith("#### Authenticated") else i
              for i in starts]
    header = "".join(lines[: starts[0]]) if starts else text
    blocks = {}
    for n, s in enumerate(starts):
        e = starts[n + 1] if n + 1 < len(starts) else len(lines)
        block = "".join(lines[s:e])
        msgid = int(re.search(r"MsgID=\s*(\d+)", block).group(1))
        blocks[msgid] = block
    return header, blocks


def make_badtag(src, dest):
    """Copy decrypt vectors from `src`, flip the LSB of the tag's first byte."""
    dest.mkdir(parents=True, exist_ok=True)
    pdi_hdr, pdi = split_msgs((src / "pdi.txt").read_text())
    do_hdr, do = split_msgs((src / "do.txt").read_text())
    n = 0
    for msgid, block in pdi.items():
        if "Opcode=Authenticated Decryption" not in block:
            continue
        # Tag segment: header 'HDR = 83...' followed by 'DAT = <tag>'.
        m = re.search(r"(Tag, .*\n(?:#.*\n)*HDR = 8[0-9A-F]{7}\n(?:#.*\n)*DAT = )([0-9A-F]{2})",
                      block)
        if not m:
            sys.exit(f"badtag: no tag found in MsgID {msgid}")
        flipped = f"{int(m.group(2), 16) ^ 0x01:02X}"
        pdi[msgid] = block[: m.start(2)] + flipped + block[m.end(2):]
        if "STT = E0000000" not in do[msgid]:
            sys.exit(f"badtag: MsgID {msgid} expected output is not a success")
        do[msgid] = (do[msgid].replace("# Status: Success", "# Status: Failure")
                              .replace("STT = E0000000", "STT = F0000000"))
        n += 1
    # Encrypt vectors stay in the file unchanged: each decrypt reuses the key its
    # preceding encrypt loaded, so dropping them would desync sdi.txt.
    (dest / "pdi.txt").write_text(pdi_hdr + "".join(pdi[k] for k in sorted(pdi)))
    (dest / "do.txt").write_text(do_hdr + "".join(do[k] for k in sorted(do)))
    shutil.copy(src / "sdi.txt", dest / "sdi.txt")
    print(f"badtag: corrupted {n} decrypt tags; {len(pdi) - n} encrypt vectors unchanged")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spec", choices=ALGO, required=True)
    ap.add_argument("--seed", type=int, default=545)
    ap.add_argument("--random", type=int, default=1000, help="number of random vectors")
    ap.add_argument("--sets", default="random,edge,full33,long,badtag,cycles,prof_short,prof_long")
    a = ap.parse_args()

    if not (LIB / "crypto_aead" / f"{ALGO[a.spec]}.so").exists():
        sys.exit("C models not built: run `make models` first")
    out = ROOT / "kat" / a.spec / "gen"
    sets = a.sets.split(",")
    aead = ["--aead", ALGO[a.spec]]

    if "random" in sets:
        run_cryptotvgen(aead + ["--max_ad", "1000", "--max_d", "1000",
                                "--gen_random", str(a.random)], out / "random", a.seed)
    if "edge" in sets or "badtag" in sets:
        pairs = [(ad, pt) for ad in AD_LENS for pt in PT_LENS]
        run_cryptotvgen(aead + ["--gen_custom", custom_spec(pairs)], out / "edge", a.seed + 1)
    if "full33" in sets:
        pairs = [(ad, pt) for ad in range(33) for pt in range(33)]
        run_cryptotvgen(aead + ["--gen_custom", custom_spec(pairs)], out / "full33", a.seed + 3)
    if "long" in sets:
        run_cryptotvgen(aead + ["--max_ad", "4000", "--max_d", "4000",
                                "--gen_custom", custom_spec(LONG)], out / "long", a.seed + 2)
    if "badtag" in sets:
        make_badtag(out / "edge", out / "badtag")
    if "cycles" in sets:
        pairs = [(ad, pt) for ad in CYC_AD for pt in CYC_PT] + CYC_EXTRA
        run_cryptotvgen(aead + ["--max_ad", "1536", "--max_d", "1536",
                                "--gen_custom", cycles_spec(pairs)], out / "cycles", a.seed + 4)
    for n, name in enumerate(PROF):
        if name in sets:
            run_cryptotvgen(aead + ["--max_ad", "1536", "--max_d", "1536",
                                    "--gen_custom", custom_spec([PROF[name]])], out / name, a.seed + 5 + n)


if __name__ == "__main__":
    main()
