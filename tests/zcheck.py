#!/usr/bin/env python3
"""Check layer 2a's decoder against Python's zlib.

    test_deflate DIR 1 -dump OUT > OUT/list && python3 tests/zcheck.py OUT

Each line of OUT/list names a stream file the test wrote and the length and
CRC-32 of the bytes PPA decoded from it; zlib must decode the same."""
import os, sys, zlib
d = sys.argv[1]
n = bad = 0
for line in open(os.path.join(d, 'list')):
    f, length, crc = line.split()
    data = open(os.path.join(d, f), 'rb').read()
    o = zlib.decompressobj(-15 if f.endswith('.raw') else 15)
    plain = o.decompress(data)
    n += 1
    if len(plain) != int(length) or zlib.crc32(plain) != int(crc, 16):
        bad += 1
        print(f'  FAIL {f}: zlib gives {len(plain)} bytes, crc {zlib.crc32(plain):08X}; PPA {length} {crc}')
print(f'{n} streams checked against zlib, {bad} different')
sys.exit(1 if bad or n == 0 else 0)
