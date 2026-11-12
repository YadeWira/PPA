#!/usr/bin/env python3
"""PPAF streams (pas/lib/ppafilter.c's format) for the fuzzer's seeds: each
.ppa of <ppa dir> (not stored) as a file record among raw records, and a
few with several files.  mkppaf.py <ppa dir> <out dir>"""
import os, random, sys

def leb(v):
    out = bytearray()
    while True:
        b = v & 0x7F; v >>= 7
        out.append(b | (0x80 if v else 0))
        if not v: return bytes(out)

def payload(ppa):
    if ppa[:3] != b'PPA' or ppa[5] & 1: return None
    pos = 8
    size = int.from_bytes(ppa[pos:pos + 8], 'little'); pos += 8 + 16
    n = ppa[pos]; pos += 1 + n + 4
    return size, ppa[pos:]

def raw(b): return b'\x00' + leb(len(b)) + b

r = random.Random(7)
src, dst = sys.argv[1], sys.argv[2]
files = []
for name in sorted(os.listdir(src)):
    p = payload(open(os.path.join(src, name), 'rb').read())
    if p and len(p[1]) < p[0]: files.append((name, p))
for name, (size, st) in files:
    s = b'PPAF\x01' + raw(bytes(r.randrange(256) for _ in range(r.randrange(1, 40))))
    s += b'\x01' + leb(size) + leb(len(st)) + st + raw(b'tail') + b'\xff'
    open(os.path.join(dst, name + '.ppaf'), 'wb').write(s)
for k in range(4):
    s = b'PPAF\x01'
    for name, (size, st) in r.sample(files, min(3, len(files))):
        s += b'\x01' + leb(size) + leb(len(st)) + st + raw(b'x' * r.randrange(1, 9))
    open(os.path.join(dst, 'multi%d.ppaf' % k), 'wb').write(s + b'\xff')
