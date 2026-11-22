"""Facts about a core read from its RTL, so result files can't disagree with the design."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_ROUNDS = re.compile(r"constant\s+PERM_ROUNDS_PER_CYCLE\s*:\s*integer\s*:=\s*(\d+)\s*;", re.I)


_GEN = re.compile(r"constant\s+G_(R|S|U)\s*:\s*integer\s*:=\s*(\d+)\s*;", re.I)


def _gen(core):
    """{'R','S','U'} for the parameterized core (rtl/core_v2_gen), else None."""
    f = ROOT / "rtl" / f"core_{core}" / "elephant_constants.vhd"
    m = dict((k.upper(), int(v)) for k, v in _GEN.findall(f.read_text())) if f.exists() else {}
    return m if len(m) == 3 else None


def rounds(core):
    """(rounds per cycle, cycles per permutation) from rtl/core_<core>/elephant_constants.vhd.

    For the parameterized core (G_R, G_S, G_U) "rounds per cycle" is the rounds per pipeline stage, R/S.
    Returns ("", "") when the core has no single PERM_ROUNDS_PER_CYCLE (e.g. an optimized core with
    differently configured units); such a core documents its configuration in its own directory.
    """
    g = _gen(core)
    if g:
        r = g["R"] // g["S"]
        return r, -(-80 // r)
    f = ROOT / "rtl" / f"core_{core}" / "elephant_constants.vhd"
    m = _ROUNDS.findall(f.read_text()) if f.exists() else []
    if len(m) != 1:
        return "", ""
    r = int(m[0])
    return r, 80 // r


def slots(core):
    """Permutation calls in flight: U*S for the parameterized core; known named cores; else 1."""
    g = _gen(core)
    if g:
        return g["U"] * g["S"]
    return {"v2_r4_optBC": 2, "v2_r4_optBCD": 4, "v2_r4_optBCDE": 4, "v2_r4_optBCDEF": 4,
            "v2_r4_optBCDEFG": 8, "v2_r4_optBCDEFGH": 8, "v2_r4_optBCDEFGHI": 8, "v2_r4_optBCDEFGHIJ": 8,
            "v2_r2_optBCDEFGH": 16, "v2_r2_optBCDEFGHI": 16, "v2_r2_optBCDEFGHIJ": 16}.get(core, 1)
