"""Shared helpers of the preflate corpus and baseline scripts (README.md).

Paths: PF (default /mnt/IA_LAB/agentes/ppa/preflate) holds tools/, corpus/
and the milestone scratch folders; nothing here writes outside PF."""
import hashlib, os, struct, subprocess, zlib

PF = os.environ.get('PF', '/mnt/IA_LAB/agentes/ppa/preflate')
TOOLS = os.path.join(PF, 'tools')
BIN = os.path.join(TOOLS, 'bin')
CORPUS = os.path.join(PF, 'corpus')
STUDY = os.environ.get('STUDY', '/mnt/IA_LAB/agentes/ppa/preflate-study')
SETS = os.environ.get('SETS', '/mnt/IA_LAB/agentes/ppa/sets')
OSR = '/mnt/OSR_D3/fileFormatSamples/fileFormatSamples'   # read only, never written
SIG = b'\x89PNG\r\n\x1a\n'

MANIFEST_COLS = ['file', 'kind', 'origin', 'encoder', 'version', 'settings', 'bytes', 'sha256', 'note']


def sha256(path_or_bytes):
    h = hashlib.sha256()
    if isinstance(path_or_bytes, (bytes, bytearray)):
        h.update(path_or_bytes)
    else:
        with open(path_or_bytes, 'rb') as f:
            for b in iter(lambda: f.read(1 << 20), b''):
                h.update(b)
    return h.hexdigest()


def write_manifest(folder, rows):
    """rows: dicts with MANIFEST_COLS (file relative to folder); bytes and
    sha256 are filled in from the file."""
    out = ['\t'.join(MANIFEST_COLS)]
    for r in sorted(rows, key=lambda r: r['file']):
        p = os.path.join(folder, r['file'])
        r = dict(r, bytes=os.path.getsize(p), sha256=sha256(p))
        out.append('\t'.join(str(r.get(c, '')).replace('\t', ' ') for c in MANIFEST_COLS))
    with open(os.path.join(folder, 'MANIFEST.tsv'), 'w') as f:
        f.write('\n'.join(out) + '\n')
    return len(rows)


def read_manifest(folder):
    rows = []
    with open(os.path.join(folder, 'MANIFEST.tsv')) as f:
        head = f.readline().rstrip('\n').split('\t')
        for line in f:
            rows.append(dict(zip(head, line.rstrip('\n').split('\t'))))
    return rows


# ---------------------------------------------------------------- PNG

def chunks(d):
    """[(type, data)] of a PNG/CgBI file, and the bytes after IEND"""
    assert d[:8] == SIG, 'not a PNG'
    pos = 8; out = []
    while pos + 8 <= len(d):
        ln, = struct.unpack('>I', d[pos:pos + 4]); t = d[pos + 4:pos + 8]
        out.append((t, d[pos + 8:pos + 8 + ln])); pos += 12 + ln
        if t == b'IEND':
            break
    return out, d[pos:]


def chunk(t, b):
    return struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)


def idat_plain(path):
    """the filtered bytes of a plain PNG's IDAT stream (not CgBI, not APNG frames)"""
    ch, _ = chunks(open(path, 'rb').read())
    if any(t == b'CgBI' for t, _ in ch):
        raise ValueError('CgBI')
    z = b''.join(b for t, b in ch if t == b'IDAT')
    o = zlib.decompressobj()
    plain = o.decompress(z)
    if not o.eof:
        raise ValueError('IDAT does not end')
    return plain


def ihdr(path):
    ch, _ = chunks(open(path, 'rb').read())
    w, h, bd, ct, cm, fm, il = struct.unpack('>IIBBBBB', ch[0][1][:13])
    return dict(w=w, h=h, bd=bd, ct=ct, il=il)


def row_bytes(info):
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[info['ct']]
    return 1 + (info['w'] * ch * info['bd'] + 7) // 8


def zlib_wrap(raw, plain, level_hint=6):
    """a raw deflate stream framed as zlib: the header zlib writes for that
    FLEVEL (0 fastest .. 3 maximum), 32K window, and the Adler-32 of plain"""
    flevel = 0 if level_hint < 2 else 1 if level_hint < 6 else 2 if level_hint == 6 else 3
    cmf = 0x78; flg = flevel << 6
    flg += 31 - ((cmf << 8) | flg) % 31
    return bytes([cmf, flg]) + raw + struct.pack('>I', zlib.adler32(plain) & 0xffffffff)


def rewrap_png(src, stream, dst, idat_size=65536):
    """src with its IDAT stream replaced by stream (a complete zlib stream),
    cut into IDATs of idat_size; every other chunk kept, in place"""
    ch, tail = chunks(open(src, 'rb').read())
    out = [SIG]; done = False
    for t, b in ch:
        if t == b'IDAT':
            if not done:
                for i in range(0, max(1, len(stream)), idat_size):
                    out.append(chunk(b'IDAT', stream[i:i + idat_size]))
                done = True
            continue
        out.append(chunk(t, b))
    with open(dst, 'wb') as f:
        f.write(b''.join(out) + tail)


def deflate_body(data):
    """(raw deflate bytes, plain) of a zlib stream (2-byte header .. Adler-32)
    or of a bare one (header None). The deflate part ends where inflate stops."""
    hdr = len(data) >= 2 and (data[0] & 15) == 8 and ((data[0] << 8) | data[1]) % 31 == 0 and not (data[1] & 32)
    body = data[2:] if hdr else data
    o = zlib.decompressobj(-15)
    plain = o.decompress(body)
    if not o.eof:
        raise ValueError('deflate does not end')
    return body[:len(body) - len(o.unused_data)], plain, hdr


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)
