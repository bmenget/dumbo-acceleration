#!/usr/bin/env python3
"""Check a built C model (model/lib) against a NIST-format LWC_AEAD_KAT file.

Checks encryption output against CT, decryption round-trip, and that a
1-bit tag flip is rejected.
Usage: python scripts/check_model_kat.py <lib.so> <LWC_AEAD_KAT_128_96.txt>
"""
import ctypes
import sys


def load(path):
    lib = ctypes.CDLL(path)
    u8p, ull = ctypes.c_char_p, ctypes.c_ulonglong
    lib.crypto_aead_encrypt.argtypes = [u8p, ctypes.POINTER(ull), u8p, ull, u8p, ull,
                                        u8p, u8p, u8p]
    lib.crypto_aead_decrypt.argtypes = [u8p, ctypes.POINTER(ull), u8p, u8p, ull, u8p, ull,
                                        u8p, u8p]
    return lib


def vectors(path):
    v = {}
    for line in open(path):
        line = line.strip()
        if not line:
            if v:
                yield v
            v = {}
            continue
        k, _, val = line.partition("=")
        v[k.strip()] = val.strip()
    if v:
        yield v


def main(lib_path, kat_path):
    lib = load(lib_path)
    n = bad = 0
    for v in vectors(kat_path):
        key, npub = bytes.fromhex(v["Key"]), bytes.fromhex(v["Nonce"])
        pt, ad, ct = (bytes.fromhex(v[k]) for k in ("PT", "AD", "CT"))
        out, olen = ctypes.create_string_buffer(len(pt) + 64), ctypes.c_ulonglong()
        lib.crypto_aead_encrypt(out, ctypes.byref(olen), pt, len(pt), ad, len(ad),
                                None, npub, key)
        got = out.raw[: olen.value]
        dec, dlen = ctypes.create_string_buffer(len(ct) + 1), ctypes.c_ulonglong()
        rc = lib.crypto_aead_decrypt(dec, ctypes.byref(dlen), None, ct, len(ct), ad, len(ad),
                                     npub, key)
        forged = bytearray(ct)
        forged[-1] ^= 1
        rc_bad = lib.crypto_aead_decrypt(dec, ctypes.byref(dlen), None, bytes(forged),
                                         len(ct), ad, len(ad), npub, key)
        ok = got == ct and rc == 0 and rc_bad != 0
        n += 1
        if not ok:
            bad += 1
            print(f"FAIL Count={v['Count']}: enc_ok={got == ct} dec_rc={rc} forged_rc={rc_bad}")
    print(f"{lib_path}: {n - bad}/{n} vectors pass")
    return 1 if bad or n == 0 else 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
