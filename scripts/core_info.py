"""Facts about a core read from its RTL, so result files can't disagree with the design."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_ROUNDS = re.compile(r"constant\s+PERM_ROUNDS_PER_CYCLE\s*:\s*integer\s*:=\s*(\d+)\s*;", re.I)


_GEN = re.compile(r"constant\s+G_(R|S|U)\s*:\s*integer\s*:=\s*(\d+)\s*;", re.I)


def _gen(core):
    """{'R','S','U'} for the parameterized core (rtl/brody/gen), else None."""
    f = ROOT / "rtl" / core / "elephant_constants.vhd"
    m = dict((k.upper(), int(v)) for k, v in _GEN.findall(f.read_text())) if f.exists() else {}
    return m if len(m) == 3 else None


def defines(core):
    """Verilog defines {NAME: int} from rtl/<core>/defines.txt (Logan's cores, rtl/logan/src/), else {}."""
    f = ROOT / "rtl" / core / "defines.txt"
    out = {}
    if f.exists():
        for line in f.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                k, v = line.split("=", 1)
                out[k.strip()] = int(v)
    return out


def rounds(core):
    """(rounds per cycle, cycles per permutation) from rtl/<core>/elephant_constants.vhd.

    For the parameterized core (G_R, G_S, G_U) "rounds per cycle" is the rounds per pipeline stage, R/S.
    Returns ("", "") when the core has no single PERM_ROUNDS_PER_CYCLE (e.g. an optimized core with
    differently configured units); such a core documents its configuration in its own directory.
    """
    g = _gen(core)
    if g:
        r = g["R"] // g["S"]
        return r, -(-80 // r)
    d = defines(core)
    if "DUMBO_R" in d:                       # Logan's iterative core: R rounds per cycle
        return d["DUMBO_R"], 80 // d["DUMBO_R"]
    if "DUMBO_K" in d:                       # Logan's ring: K rounds per stage
        return d["DUMBO_K"], 80 // d["DUMBO_K"]
    f = ROOT / "rtl" / core / "elephant_constants.vhd"
    m = _ROUNDS.findall(f.read_text()) if f.exists() else []
    if len(m) != 1:
        return "", ""
    r = int(m[0])
    return r, 80 // r


def slots(core):
    """Permutation calls in flight: U*S for the parameterized core; S for Logan's ring; known named cores; else 1."""
    g = _gen(core)
    if g:
        return g["U"] * g["S"]
    d = defines(core)
    if "DUMBO_S" in d:                       # Logan's ring: S stages, one call each
        return d["DUMBO_S"]
    return {"brody/r4_BtoC": 2, "brody/r4_BtoD": 4, "brody/r4_BtoE": 4, "brody/r4_BtoF": 4,
            "brody/r4_BtoG": 8, "brody/r4_BtoH": 8, "brody/r4_BtoI": 8, "brody/r4_BtoJ": 8,
            "brody/r2_BtoH": 16, "attic/brody/r2_BtoI": 16, "attic/brody/r2_BtoJ": 16,
            "attic/brody/r2_BtoK": 16, "brody/r2_BtoL": 16,
            "merged/r2_BtoM": 16}.get(core, 1)
