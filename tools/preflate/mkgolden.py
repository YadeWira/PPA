#!/usr/bin/env python3
"""The golden vectors of the deflate recipes (doc/PREFLATE.md, "The
versioning rule"): deflate streams by many encoders, each beside the recipe
PPA's encoder made of it, committed in tests/recipes/. The suite checks on
every platform, with the C and the Pascal code, that each recipe still
gives its stream back bit for bit (pas/tests/test_preflate -golden). A
published recipe format never changes what it gives; these files are how
that is checked.

    python3 tools/preflate/mkgolden.py OUTDIR      the streams and MANIFEST.tsv
    test_preflate OUTDIR 1 -writegolden            then each one's .recipe

    python3 tools/preflate/mkgolden.py --kind2 tests/recipes
                                                   kind 2's (miniz), added beside
                                                   the others (M5, 15/11/2026)

Run once per recipe format; the files are committed, not made again (a
new format adds its own next to them). The encoders are the study's builds
($PF/tools/bin, tools/preflate/build_tools.sh: libdeflate 1.23, miniz 1.14
and 3.0, zopfli, zlib 1.3.1, 1.2.5 and 1.2.3, pngcrush, advancecomp) and
Python's zlib. The bytes they code are PPA's own: images inflated from
tests/png, synthetic images and text made here, a part of doc/CODEC.md.
"""
import os, random, struct, subprocess, sys, zlib

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BIN = os.path.join(os.environ.get('PF', '/mnt/IA_LAB/agentes/ppa/preflate'), 'tools', 'bin')


def idat_plain(path):
    b = open(path, 'rb').read()
    i, idat = 8, b''
    while i < len(b):
        n, t = struct.unpack('>I4s', b[i:i + 8])
        if t == b'IDAT':
            idat += b[i + 8:i + 8 + n]
        i += 12 + n
    return zlib.decompress(idat)


def photo(w, h, seed):
    """an RGB image of smooth gradients and a little noise, its rows
    filtered with Sub (each sample less the one to its left) or Up, as an
    encoder would: what a photo's plain looks like"""
    r = random.Random(seed)
    img = [[[(x * (c + 2) + y * (3 - c) * 2 + (x * y >> 6) + r.randrange(0, 5)) & 255 for c in range(3)]
            for x in range(w)] for y in range(h)]
    rows = []
    for y in range(h):
        f = 1 if y == 0 or r.random() < 0.6 else 2
        row = bytearray([f])
        for x in range(w):
            for c in range(3):
                if f == 1:
                    left = img[y][x - 1][c] if x else 0
                    row.append((img[y][x][c] - left) & 255)
                else:
                    row.append((img[y][x][c] - img[y - 1][x][c]) & 255)
        rows.append(bytes(row))
    return b''.join(rows)


def drawing(w, h, seed):
    """a palette-like drawing: flat areas, runs, a few edges (8-bit gray)"""
    r = random.Random(seed)
    rects = [(r.randrange(w), r.randrange(h), r.randrange(4, w // 2), r.randrange(4, h // 2), r.randrange(256))
             for _ in range(24)]
    out = bytearray()
    for y in range(h):
        out.append(0)
        for x in range(w):
            v = 255
            for (x0, y0, rw, rh, c) in rects:
                if x0 <= x < x0 + rw and y0 <= y < y0 + rh:
                    v = c
            out.append(v)
    return bytes(out)


def binary(n, seed):
    """structured binary: records of little-endian fields, some repeated"""
    r = random.Random(seed)
    out = bytearray()
    names = [bytes(r.randrange(97, 123) for _ in range(r.randrange(4, 12))) for _ in range(40)]
    while len(out) < n:
        out += struct.pack('<IHH', r.randrange(1 << 20), r.randrange(64), 0x7FFF)
        out += r.choice(names) + b'\0'
        out += bytes(r.randrange(4) for _ in range(r.randrange(0, 9)))
    return bytes(out[:n])


def zipf(n, seed):
    """bytes of a long-tailed distribution: deep Huffman trees, where the
    builders' length limits differ (miniz's tree)"""
    r = random.Random(seed)
    w = [1 / (i + 1) ** 1.6 for i in range(256)]
    return bytes(r.choices(range(256), weights=w, k=n))


def png_gray(plain, w, h):
    """a PNG of 8-bit gray w x h whose filtered rows are plain"""
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 0, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(plain, 9)) + chunk(b'IEND', b''))


def mixed(seed):
    """a photo, 40 KB of noise and text: miniz's blocks end where its code
    buffer fills and past 31 KB, and the noise's go stored"""
    r = random.Random(seed)
    return (photo(96, 64, seed) + bytes(r.randrange(256) for _ in range(40000)) +
            open(os.path.join(REPO, 'doc', 'CODEC.md'), 'rb').read()[:30000])


def main():
    if sys.argv[1] == '--kind2':
        return kind2(sys.argv[2])
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    tmp = os.path.join(out, '.plain')
    os.makedirs(tmp, exist_ok=True)
    plains = {
        'rgb8': idat_plain(os.path.join(REPO, 'tests', 'png', 'rgb8.png')),
        'rgba8': idat_plain(os.path.join(REPO, 'tests', 'png', 'rgba8.png')),
        'photo': photo(96, 64, 1),
        'drawing': drawing(160, 100, 2),
        'text': open(os.path.join(REPO, 'doc', 'CODEC.md'), 'rb').read()[:14000],
        'bin': binary(16000, 3),
        'zipf': zipf(40000, 5),
    }
    # the text as the rows of a gray image (each row's filter byte 0)
    plains['textimg'] = b''.join(b'\0' + plains['text'][y * 139:(y + 1) * 139] for y in range(100))
    for k, v in plains.items():
        open(os.path.join(tmp, k), 'wb').write(v)
    man = []

    def tool(name, ext, plain, *args):
        cmd = [os.path.join(BIN, args[0])] + [os.path.join(tmp, plain)] + list(args[1:])
        data = subprocess.run(cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
        put(name, ext, plain, ' '.join([args[0], plain] + list(args[1:])), data)

    def put(name, ext, plain, how, data):
        open(os.path.join(out, name + '.' + ext), 'wb').write(data)
        man.append((name + '.' + ext, plain, len(plains[plain]), len(data), how))

    def pyz(name, plain, level, wbits=15, mem=8, strategy=0, flushes=(), ext=None):
        c = zlib.compressobj(level, zlib.DEFLATED, wbits, mem, strategy)
        p, at, data = plains[plain], 0, b''
        for pos, f in flushes:
            data += c.compress(p[at:pos]) + c.flush(f)
            at = pos
        data += c.compress(p[at:]) + c.flush()
        put(name, ext or ('raw' if wbits < 0 else 'zlib'), plain,
            'python zlib %s level %d wbits %d mem %d strategy %d flushes %s' % (zlib.ZLIB_RUNTIME_VERSION, level, wbits,
                                                                               mem, strategy, list(flushes)), data)

    # kind 0: zlib's parameters
    pyz('rgb8-z6', 'rgb8', 6)
    pyz('text-z9-filtered', 'text', 9, strategy=zlib.Z_FILTERED)
    pyz('bin-z1-mem1-w9-raw', 'bin', 1, wbits=-9, mem=1)
    pyz('drawing-z4-rle', 'drawing', 4, strategy=zlib.Z_RLE)
    pyz('photo-z2-huffman', 'photo', 2, strategy=zlib.Z_HUFFMAN_ONLY)
    pyz('rgba8-z9-fixed', 'rgba8', 9, strategy=zlib.Z_FIXED)
    # kind 1: zlib with its flushes and parameter changes, three zlibs
    tool('text-flows-131', 'zlib', 'text', 'zfl', '6', '8', '15', '0',
         '2000:sync', '4000:full', '6000:partial', '8000:block', '10000:params=9,1', '12000:params=2,0')
    tool('photo-partial-125', 'zlib', 'photo', 'zfl-1.2.5', '9', '8', '15', '0',
         '4000:partial', '4001:partial', '9000:partial', '14000:sync')
    tool('photo-full-123', 'zlib', 'photo', 'zfl-1.2.3', '6', '9', '15', '1', '5000:full', '12000:partial')
    tool('bin-params-raw-131', 'raw', 'bin', 'zfl', '9', '8', '-15', '0', '5000:block', '5000:params=1,0',
         '10000:full', '10000:params=7,0')
    pyz('drawing-pysync', 'drawing', 6, flushes=((4000, zlib.Z_SYNC_FLUSH), (9000, zlib.Z_FULL_FLUSH)))
    tool('text-full-123-w9', 'zlib', 'text', 'zfl-1.2.3', '6', '8', '9', '0', '3000:full', '7000:full', '7100:full',
         '11000:full')
    # pngcrush -m 1: zlib 1.2.11 built with TOO_FAR 32767 (ZV_NO_TOO_FAR)
    png = os.path.join(tmp, 'textimg.png')
    open(png, 'wb').write(png_gray(plains['textimg'], 139, 100))
    subprocess.run([os.path.join(BIN, 'pngcrush'), '-q', '-force', '-m', '1', png, png + '.c'], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    b = open(png + '.c', 'rb').read()
    i, idat = 8, b''
    while i < len(b):
        n, t = struct.unpack('>I4s', b[i:i + 8])
        if t == b'IDAT':
            idat += b[i + 8:i + 8 + n]
        i += 12 + n
    put('textimg-pngcrush-m1', 'zlib', 'textimg', 'pngcrush 1.8.13 -m 1 of textimg as a gray PNG, its IDAT', idat)
    os.remove(png); os.remove(png + '.c')
    # kind 3: other encoders, each tree builder
    tool('photo-ldf1', 'raw', 'photo', 'ldf', '1')
    tool('photo-ldf6', 'raw', 'photo', 'ldf', '6')
    tool('photo-ldf12', 'raw', 'photo', 'ldf', '12')
    tool('text-ldf12', 'raw', 'text', 'ldf', '12')
    tool('drawing-ldf9', 'raw', 'drawing', 'ldf', '9')
    tool('photo-mz114-9', 'raw', 'photo', 'mz114', '9')
    tool('text-mz114-10', 'raw', 'text', 'mz114', '10')
    tool('bin-mz3-6-greedy', 'raw', 'bin', 'mz3', '6', '1')
    tool('drawing-mz3-1', 'raw', 'drawing', 'mz3', '1')
    tool('zipf-mz114-1', 'raw', 'zipf', 'mz114', '1')
    tool('photo-zopfli', 'raw', 'photo', 'zop', '5')
    tool('text-zopfli', 'raw', 'text', 'zop', '5')
    tool('rgba8-zopfli', 'raw', 'rgba8', 'zop', '15')
    pyz('rgb8-z0-stored', 'rgb8', 0)
    # kind 3 framing: a wrong Adler-32 and bytes after the stream; pad bits set
    d = open(os.path.join(out, 'photo-ldf6.raw'), 'rb').read()
    z = b'\x78\xda' + d + struct.pack('>I', zlib.adler32(plains['photo']) ^ 1) + b'tail'
    put('photo-ldf6-badadler-tail', 'zlib', 'photo', 'photo-ldf6.raw in a zlib frame, Adler-32 xor 1, 4 bytes after',
        z)
    d = bytearray(open(os.path.join(out, 'text-ldf12.raw'), 'rb').read())
    put('text-ldf12-pad', 'raw', 'text', 'text-ldf12.raw with its last byte or 0x80 (pad bits)',
        bytes(d[:-1]) + bytes([d[-1] | 0x80]))
    with open(os.path.join(out, 'MANIFEST.tsv'), 'w') as f:
        f.write('file\tplain\tplain_bytes\tbytes\tmade by\n')
        for r in man:
            f.write('\t'.join(str(x) for x in r) + '\n')
    for k in plains:
        os.remove(os.path.join(tmp, k))
    os.rmdir(tmp)
    print('%d streams in %s' % (len(man), out))


def kind2(out):
    """kind 2's vectors (miniz's tdefl, ppaminiz): each of its paths, beside
    the others, MANIFEST.tsv appended; then -writegolden writes the
    recipes of the streams that have none"""
    tmp = os.path.join(out, '.plain')
    os.makedirs(tmp, exist_ok=True)
    plains = {
        'photo': photo(96, 64, 1),
        'drawing': drawing(160, 100, 2),
        'text': open(os.path.join(REPO, 'doc', 'CODEC.md'), 'rb').read()[:14000],
        'bin': binary(16000, 3),
        'zipf': zipf(40000, 5),
        'mixed': mixed(7),
    }
    for k, v in plains.items():
        open(os.path.join(tmp, k), 'wb').write(v)
    G, ZH = 0x4000, 0x1000
    cases = [
        # name, plain, tool, flags: the level-1 loop (1.14 on x86), the normal one at
        # level 1 (3.x), levels 6 and 9 (lazy), 10, the PNG writer's (no greedy, zlib
        # framed), filtered, RLE, Huffman only, static codes, raw; and many blocks
        ('text-mzk2-114-L1fast', 'text', 'mzf114', 1 | G),
        ('text-mzk2-3-L1', 'text', 'mzf3', 1 | G),
        ('bin-mzk2-3-L6', 'bin', 'mzf3', 128),
        ('zipf-mzk2-114-L9', 'zipf', 'mzf114', 768),
        ('zipf-mzk2-3-L10', 'zipf', 'mzf3', 1500),
        ('photo-mzk2-3-png6', 'photo', 'mzf3', 128 | ZH),
        ('text-mzk2-3-filtered', 'text', 'mzf3', 128 | 0x20000),
        ('drawing-mzk2-3-rle', 'drawing', 'mzf3', 128 | 0x10000),
        ('photo-mzk2-3-huffman', 'photo', 'mzf3', 0),
        ('bin-mzk2-3-static', 'bin', 'mzf3', 128 | 0x40000),
        ('drawing-mzk2-3-L0', 'drawing', 'mzf3', G | 0x80000),
        ('mixed-mzk2-3-L6', 'mixed', 'mzf3', 128),
        ('mixed-mzk2-3u-L1fast', 'mixed', 'mzf3u', 1 | G),
        ('mixed-mzk2-3-L0', 'mixed', 'mzf3', G | 0x80000),
    ]
    man = []
    for name, plain, t, flags in cases:
        ext = 'zlib' if flags & ZH else 'raw'
        data = subprocess.run([os.path.join(BIN, t), os.path.join(tmp, plain), str(flags)], check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
        open(os.path.join(out, name + '.' + ext), 'wb').write(data)
        man.append((name + '.' + ext, plain, len(plains[plain]), len(data), '%s %s 0x%x' % (t, plain, flags)))
    with open(os.path.join(out, 'MANIFEST.tsv'), 'a') as f:
        for r in man:
            f.write('\t'.join(str(x) for x in r) + '\n')
    for k in plains:
        os.remove(os.path.join(tmp, k))
    os.rmdir(tmp)
    print('%d streams added in %s' % (len(man), out))


main()
