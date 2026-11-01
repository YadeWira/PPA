#!/usr/bin/env python3
"""Make the "generated" benchmark set: a few base images (from the shared
corpus and PJA's photos) written by different encoders and settings, so
that the set has what PNG writers vary: zlib's level, filter and strategy,
colour type and depth, interlacing, and encoders that are not zlib.

    python3 tools/bench/mkgen.py OUT

Needs ImageMagick (convert: libpng, i.e. zlib), optipng (zlib) and oxipng
(libdeflate: not zlib, so PPA keeps those streams as bytes)."""
import os, subprocess, sys, shutil

OUT = sys.argv[1]
C = '/mnt/IA_LAB/agentes/ppa/corpus/png/'
P = '/mnt/IA_LAB/agentes/pja/b151/in/'
BASES = {
    'photo': (P + '0028B2CCB.jpg', ['-resize', '960x960>']),
    'graphic': (C + 'image__png__diagram.png', []),
    'rgba': (C + 'image__png__abydos.png', []),
    'art': (C + 'image__png__antiqhvy.png', []),
    'icon': (C + 'image__lottie__images__img_0.png', []),
}
NOTIME = ['-define', 'png:exclude-chunks=date,time']


def im(src, pre, args, out):
    subprocess.run(['convert', src] + pre + args + NOTIME + [out], check=True)


os.makedirs(OUT, exist_ok=True)
for name, (src, pre) in BASES.items():
    # zlib's level, filter and strategy (ImageMagick's png:compression-*)
    for lv in (1, 6, 9):
        for filt in (0, 5):
            im(src, pre, ['-define', f'png:compression-level={lv}', '-define', f'png:compression-filter={filt}'],
               f'{OUT}/{name}_l{lv}_f{filt}.png')
    im(src, pre, ['-define', 'png:compression-strategy=2'], f'{OUT}/{name}_huffman.png')
    im(src, pre, ['-define', 'png:compression-strategy=3'], f'{OUT}/{name}_rle.png')
    # colour type and depth, interlacing
    im(src, pre, ['-colorspace', 'gray', '-depth', '8'], f'{OUT}/{name}_gray.png')
    im(src, pre, ['-colors', '256'], f'{OUT}/{name}_pal256.png')
    im(src, pre, ['-depth', '16'], f'{OUT}/{name}_16bit.png')
    im(src, pre, ['-interlace', 'PNG'], f'{OUT}/{name}_adam7.png')
    # other encoders: optipng (zlib, its own search), oxipng (libdeflate)
    im(src, pre, [], f'{OUT}/{name}_base.png')
    shutil.copy(f'{OUT}/{name}_base.png', f'{OUT}/{name}_optipng.png')
    subprocess.run(['optipng', '-quiet', '-o2', f'{OUT}/{name}_optipng.png'], check=True)
    shutil.copy(f'{OUT}/{name}_base.png', f'{OUT}/{name}_oxipng.png')
    subprocess.run(['oxipng', '-q', '-o', '2', f'{OUT}/{name}_oxipng.png'], check=True)
