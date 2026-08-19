#!/usr/bin/env python3
"""Resoudre une adresse virtuelle SLPI en chaine, depuis l'image PIL scindee.

Les ULog du DSP ne stockent que le pointeur de la chaine de format, pas la
chaine. Les segments charges sont exactement ceux de slpi.mdt, dont le contenu
vit dans les slpi.b<NN> voisins, donc une adresse se resout sans supposition :
on trouve le segment qui la contient et on lit a l'offset correspondant.
"""
import struct
import sys
import os

IMG = "/tmp/claude-1000/-home-srobin-Projects-OnePlus-7T-Pro---Linux/6d2ef522-6c80-436a-99e7-99346c5e9f0f/scratchpad/414/fwreal"


def segments():
    d = open(os.path.join(IMG, "slpi.mdt"), "rb").read()
    phoff = struct.unpack("<I", d[0x1C:0x20])[0]
    phentsize = struct.unpack("<H", d[0x2A:0x2C])[0]
    phnum = struct.unpack("<H", d[0x2C:0x2E])[0]
    out = []
    for i in range(phnum):
        o = phoff + i * phentsize
        t, off, va, pa, fsz, msz, fl, al = struct.unpack("<IIIIIIII", d[o:o + 32])
        if t == 1 and fsz:
            out.append((i, va, fsz))
    return out


SEGS = segments()
_cache = {}


def read(va, n=256):
    for i, base, size in SEGS:
        if base <= va < base + size:
            if i not in _cache:
                p = os.path.join(IMG, "slpi.b%02d" % i)
                if not os.path.exists(p):
                    return None
                _cache[i] = open(p, "rb").read()
            b = _cache[i]
            off = va - base
            return b[off:off + n]
    return None


def string(va, back=96):
    """Chaine complete contenant va.

    Le pointeur journalise ne tombe pas toujours sur le premier octet : on
    remonte jusqu'au NUL precedent pour restituer le message entier plutot
    qu'un fragment, et on marque le point d'entree par un |.
    """
    b = read(va - back, back + 400)
    if b is None:
        return None
    head = b[:back]
    start = head.rfind(b"\0")
    start = start + 1 if start >= 0 else 0
    rest = b[start:]
    e = rest.find(b"\0")
    s = rest[:e if e >= 0 else len(rest)]
    mark = back - start
    try:
        t = s.decode("utf-8")
    except UnicodeDecodeError:
        return repr(s)
    return t[:mark] + "|" + t[mark:] if 0 < mark < len(t) else t


if __name__ == "__main__":
    for a in sys.argv[1:]:
        va = int(a, 16)
        print("0x%08x -> %s" % (va, string(va)))
