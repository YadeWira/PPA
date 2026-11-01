#!/usr/bin/env python3
"""Make the synthetic samples in tests/png/ (tests/README.md says what each is).

    python3 tests/mkpng.py tests/png

Every image is a fractal plasma from ImageMagick with a fixed seed, or built
here byte by byte; the special cases (chunks cut differently, a wrong CRC,
bytes after IEND, APNG frames) are made by rewriting chunks. Needs `convert`.
"""
import os, struct, subprocess, sys, tempfile, zlib

OUT = sys.argv[1] if len(sys.argv) > 1 else 'tests/png'
PNG_SIG = b'\x89PNG\r\n\x1a\n'


def chunk(typ, data, crc=None):
    if crc is None:
        crc = zlib.crc32(typ + data) & 0xFFFFFFFF
    return struct.pack('>I', len(data)) + typ + data + struct.pack('>I', crc)


def chunks(png):
    """[(type, data)] of a PNG/MNG/JNG file, its signature skipped"""
    out, pos = [], 8
    while pos + 12 <= len(png):
        n, = struct.unpack('>I', png[pos:pos + 4])
        out.append((png[pos + 4:pos + 8], png[pos + 8:pos + 8 + n]))
        pos += 12 + n
    return out


def convert(args, ext):
    with tempfile.TemporaryDirectory() as t:
        f = os.path.join(t, 'x.' + ext)
        subprocess.run(['convert'] + args + [f], check=True)
        return open(f, 'rb').read()


def plasma(seed, w, h, *extra, ext='png'):
    return convert(['-seed', str(seed), '-size', f'{w}x{h}', 'plasma:fractal'] + list(extra)
                   + ['-define', 'png:exclude-chunks=date,time'], ext)


def write(name, data):
    with open(os.path.join(OUT, name), 'wb') as f:
        f.write(data)


def rebuild(cs, sig=PNG_SIG):
    return sig + b''.join(chunk(t, d) for t, d in cs)


def idat_of(cs):
    return b''.join(d for t, d in cs if t == b'IDAT')


def main():
    os.makedirs(OUT, exist_ok=True)
    # the colour types and depths, as ImageMagick (libpng) writes them
    write('rgb8.png', plasma(1, 64, 48, '-define', 'png:color-type=2'))
    write('rgba8.png', plasma(2, 48, 48, '-alpha', 'set', '-channel', 'A', '-evaluate', 'set', '60%',
                              '+channel', '-define', 'png:color-type=6'))
    write('gray8.png', plasma(3, 64, 32, '-colorspace', 'gray', '-define', 'png:color-type=0'))
    write('gray1.png', plasma(4, 40, 24, '-colorspace', 'gray', '-monochrome', '-define', 'png:bit-depth=1'))
    write('palette.png', convert(['-seed', '5', '-size', '48x32', 'plasma:fractal', '-colors', '16',
                                  '-define', 'png:exclude-chunks=date,time'], 'png8'))
    write('rgb16.png', plasma(6, 32, 32, '-depth', '16', '-define', 'png:color-type=2'))
    write('interlaced.png', plasma(7, 56, 40, '-interlace', 'PNG'))

    base = open(os.path.join(OUT, 'rgb8.png'), 'rb').read()
    cs = chunks(base)
    idat = idat_of(cs)
    head = [(t, d) for t, d in cs if t not in (b'IDAT', b'IEND')]

    # the same stream cut into 100-byte IDATs, with an empty one in the middle
    pieces = [(b'IDAT', idat[i:i + 100]) for i in range(0, len(idat), 100)]
    pieces.insert(len(pieces) // 2, (b'IDAT', b''))
    write('idat_split.png', rebuild(head + pieces + [(b'IEND', b'')]))

    # a tEXt with a wrong CRC, and bytes after IEND
    bad = PNG_SIG + b''.join(chunk(t, d) for t, d in head) + \
        chunk(b'tEXt', b'Comment\x00made by mkpng.py', crc=0x12345678) + \
        chunk(b'IDAT', idat) + chunk(b'IEND', b'') + b'trailing bytes after IEND\n'
    write('bad_crc_trailer.png', bad)

    # cut short in the middle of its IDAT
    write('cut_short.png', base[:len(base) * 2 // 3])

    # an APNG of 3 frames: IDAT is frame 0, fdAT frames 1 and 2 (each split in two)
    ihdr = cs[0][1]
    w, h = struct.unpack('>II', ihdr[:8])
    frames = []
    for seed in (11, 12, 13):
        frames.append(idat_of(chunks(plasma(seed, w, h, '-define', 'png:color-type=2'))))
    seq = 0
    out = [(b'IHDR', ihdr), (b'acTL', struct.pack('>II', 3, 0))]
    for k, fr in enumerate(frames):
        out.append((b'fcTL', struct.pack('>IIIIIHHBB', seq, w, h, 0, 0, 1, 10, 0, 0)))
        seq += 1
        if k == 0:
            out.append((b'IDAT', fr))
        else:
            half = len(fr) // 2
            for part in (fr[:half], fr[half:]):
                out.append((b'fdAT', struct.pack('>I', seq) + part))
                seq += 1
    out.append((b'IEND', b''))
    write('apng3.png', rebuild(out))

    # JNG and MNG as ImageMagick writes them
    write('color.jng', plasma(21, 64, 48, '-quality', '85', ext='jng'))
    write('alpha.jng', plasma(22, 48, 32, '-alpha', 'set', '-channel', 'A', '-evaluate', 'set', '50%',
                              '+channel', '-quality', '80', ext='jng'))
    write('anim.mng', convert(['-delay', '10', '-size', '32x32', '-seed', '31', 'plasma:fractal',
                               '-seed', '32', 'plasma:fractal', '-seed', '33', 'plasma:fractal'], 'mng'))


if __name__ == '__main__':
    main()
