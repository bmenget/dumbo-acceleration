"""Facts about a core read from its RTL, so result files can't disagree with the design."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
_ROUNDS = re.compile(r"constant\s+PERM_ROUNDS_PER_CYCLE\s*:\s*integer\s*:=\s*(\d+)\s*;", re.I)


def rounds(core):
    """(rounds per cycle, cycles per permutation) from rtl/core_<core>/elephant_constants.vhd.

    Returns ("", "") when the core has no single PERM_ROUNDS_PER_CYCLE (e.g. an optimized core with
    differently configured units); such a core documents its configuration in its own directory.
    """
    f = ROOT / "rtl" / f"core_{core}" / "elephant_constants.vhd"
    m = _ROUNDS.findall(f.read_text()) if f.exists() else []
    if len(m) != 1:
        return "", ""
    r = int(m[0])
    return r, 80 // r
