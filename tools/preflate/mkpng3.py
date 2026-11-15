#!/usr/bin/env python3
"""tests/png3: PNGs whose image data no zlib parameters give alone, for codec
stream version 3 (an image's deflate recipe of kind 1 or 3, doc/CODEC.md
"Layer 6"). Each is one of tests/png with its IDAT written again by another
encoder (the study's builds, $PF/tools/bin: libdeflate 1.23, zopfli, miniz
1.14, zlib 1.3.1 with flushes), the same pixels. Made once and committed.

    python3 tools/preflate/mkpng3.py tests/png3
"""
import os, struct, subprocess, sys, zlib

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BIN = os.path.join(os.environ.get('PF', '/mnt/IA_LAB/agentes/ppa/preflate'), 'tools', 'bin')


def chunks(b):
    i = 8
    while i < len(b):
        n, t = struct.unpack('>I4s', b[i:i + 8])
        yield t, b[i + 8:i + 8 + n]
        i += 12 + n


def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    tmp = os.path.join(out, '.plain')
    jobs = [  # (source, new name, encoder command after the plain's path, framing)
        ('rgb8.png', 'rgb8-libdeflate12.png', ['ldf', '12'], 'raw'),
        ('rgba8.png', 'rgba8-zopfli.png', ['zop', '15'], 'raw'),
        ('gray8.png', 'gray8-miniz9.png', ['mz114', '9'], 'raw'),
        ('interlaced.png', 'interlaced-libdeflate6.png', ['ldf', '6'], 'raw'),
        ('rgb16.png', 'rgb16-zlib-flushes.png', ['zfl', '9', '8', '15', '0', '1500:sync', '3000:full', '4500:partial'],
         'zlib'),
    ]
    for src, name, cmd, framing in jobs:
        b = open(os.path.join(REPO, 'tests', 'png', src), 'rb').read()
        idat = b''.join(d for t, d in chunks(b) if t == b'IDAT')
        plain = zlib.decompress(idat)
        open(tmp, 'wb').write(plain)
        data = subprocess.run([os.path.join(BIN, cmd[0]), tmp] + cmd[1:], check=True, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL).stdout
        if framing == 'raw':
            data = b'\x78\xda' + data + struct.pack('>I', zlib.adler32(plain))
        assert zlib.decompress(data) == plain
        o, done = b[:8], False
        for t, d in chunks(b):
            if t == b'IDAT':
                if not done:
                    o += chunk(b'IDAT', data)
                    done = True
            else:
                o += chunk(t, d)
        open(os.path.join(out, name), 'wb').write(o)
        print('%s: %s, %d -> %d bytes of image data' % (name, ' '.join(cmd), len(idat), len(data)))
    os.remove(tmp)


main()
