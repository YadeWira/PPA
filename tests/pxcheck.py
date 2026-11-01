#!/usr/bin/env python3
"""Check layer 3's unfiltered bytes against ImageMagick.

    test_pixels DIR 1 -dump OUT > OUT/list && python3 tests/pxcheck.py OUT

Each line of OUT/list names a raw file the test wrote (the unfiltered bytes
of a non-interlaced 8-bit gray, RGB or RGBA PNG), the PNG and its colour
type; ImageMagick must decode the same bytes. CgBI PNGs (an iPhone's: BGRA,
premultiplied) and files that are not PNG are skipped."""
import os, subprocess, sys
d = sys.argv[1]
n = bad = skipped = 0
for line in open(os.path.join(d, 'list')):
    k, path, ctype = line.rsplit(' ', 2)[0].split(' ', 1)[0], line.split(' ', 1)[1].rsplit(' ', 1)[0], line.split()[-1]
    data = open(path, 'rb').read()
    if not data.startswith(b'\x89PNG') or data[12:16] == b'CgBI':
        skipped += 1
        continue
    fmt = {'0': 'gray', '2': 'rgb', '6': 'rgba'}[ctype]
    im = subprocess.run(['convert', path + '[0]', '-depth', '8', fmt + ':-'], capture_output=True, check=True).stdout
    mine = open(os.path.join(d, k + '.raw'), 'rb').read()
    n += 1
    if im != mine:
        bad += 1
        print(f'  FAIL {os.path.basename(path)}: ImageMagick {len(im)} bytes, PPA {len(mine)}')
print(f'{n} images checked against ImageMagick, {bad} different, {skipped} skipped')
sys.exit(1 if bad or n == 0 else 0)
