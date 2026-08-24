#!/usr/bin/env python3
"""Lecteur a acces direct pour une image sparse Android.

Evite de decompresser quinze gigaoctets pour en lire un : on indexe les
morceaux une fois, puis on ne lit que la plage demandee.
"""
import struct, sys

class Sparse:
    def __init__(self, chemin):
        self.f = open(chemin, "rb")
        e = self.f.read(28)
        (magic, maj, minr, fhs, chs, self.blk, self.total_blk,
         self.total_chunks, crc) = struct.unpack("<IHHHHIIII", e)
        assert magic == 0xED26FF3A, "pas une image sparse"
        self.carte = []          # (bloc_debut, nb_blocs, type, offset_fichier)
        pos = fhs
        bloc = 0
        for _ in range(self.total_chunks):
            self.f.seek(pos)
            ctype, res, nb, sz = struct.unpack("<HHII", self.f.read(12))
            data = pos + chs
            self.carte.append((bloc, nb, ctype, data))
            bloc += nb
            pos += sz
    def lire(self, offset, longueur):
        out = bytearray()
        while longueur > 0:
            b = offset // self.blk
            d = offset % self.blk
            trouve = None
            for deb, nb, ctype, data in self.carte:
                if deb <= b < deb + nb:
                    trouve = (deb, nb, ctype, data); break
            if trouve is None:
                out += b"\0" * longueur; break
            deb, nb, ctype, data = trouve
            n = min(longueur, self.blk - d, (deb + nb - b) * self.blk - d)
            if ctype == 0xCAC1:              # brut
                self.f.seek(data + (b - deb) * self.blk + d)
                out += self.f.read(n)
            elif ctype == 0xCAC2:            # remplissage
                self.f.seek(data)
                motif = self.f.read(4)
                out += (motif * (n // 4 + 2))[:n]
            else:                            # trou
                out += b"\0" * n
            offset += n; longueur -= n
        return bytes(out)

if __name__ == "__main__":
    s = Sparse(sys.argv[1])
    print("blocs %d de %d octets, %d morceaux -> %d octets"
          % (s.total_blk, s.blk, s.total_chunks, s.total_blk * s.blk))
    tete = s.lire(0, 1 << 16)
    g = tete.find(struct.pack("<I", 0x616C4467))
    h = tete.find(struct.pack("<I", 0x414C5030))
    print("geometrie a 0x%x, en-tete a 0x%x" % (g, h))
