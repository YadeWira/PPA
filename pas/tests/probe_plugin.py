#!/usr/bin/env python3
"""The zpaq-std plugin as zpaq-std sees it (its C ABI, through ctypes): the
codec it lists, which files it takes, and its compress, query, data and
decompress on them. As PJA's pas/tests/probe_plugin.py.

    probe_plugin.py <ppa.so> [--max-bytes N] [--sample K] [--threads T]
                    [--dumps DIR] [--need-refusals] <dir or file> ...

Checks:
  - one codec, ppa1, at 0 and nothing past it; abi 1, levels 1..1; its
    library field starts with "ppa1: PPA stream v2, static model"; its
    ZPAQL given only with $3..$5 (data(ZS_DATA_ZPAQL_ARGS), config
    "comp 0 0 $3 $4 0 / hcomp halt / pcomp ppa1 ;"), the very text of
    pas/plugin/ppa1zpaql.inc, and none as data(ZS_DATA_ZPAQL); its card;
    query(ZS_QUERY_SEGMENTS) = 1; zpaqstd_codec_v1 is ppa1;
  - detect takes exactly the files this script's own reading of the chunks
    says (a PNG, APNG or MNG, no JNG chunk, every IHDR of 8-bit gray, gray +
    alpha, RGB or RGBA, Adam7 or not, every IDAT and fdAT run inside such
    an image), and refuses every palette, 1/2/4/16-bit and JNG file (the
    refusals counted: --need-refusals demands some of both); another
    codec name is refused;
  - each file taken, of at most --max-bytes (default 4 MB; with --sample K,
    K of each directory, spread over it): compress (with zpaq-std's list of
    fragments after it too: the bytes come back), query within PPA1_MAX_PH
    and PPA1_MAX_PM, H at least 2^21, decompress back byte for byte, and a
    damaged stream refused or different, never a crash;
  - --dumps DIR (pas/tests/dump_streams' output): for each file dumped
    there, the stream compress() gives is the dump's, and the query's $3
    and $4 are those of tools/zpaql/test_ppadec.py's needs().

Prints, per directory, how many files detect took and how many came back,
and the largest queries. Exit code 1 on any failure."""
import ctypes as C, os, re, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
INC = os.path.join(REPO, 'pas', 'plugin', 'ppa1zpaql.inc')
ARGS_SRC = os.path.join(REPO, 'pas', 'plugin', 'ppazpaqlargs.pas')

BOUND = C.CFUNCTYPE(C.c_size_t, C.c_size_t, C.c_int)
COMP = C.CFUNCTYPE(C.c_longlong, C.c_void_p, C.c_size_t, C.c_void_p, C.c_size_t, C.c_int)
QUERY = C.CFUNCTYPE(C.c_longlong, C.c_int, C.c_void_p, C.c_size_t)
DATA = C.CFUNCTYPE(C.c_void_p, C.c_int, C.POINTER(C.c_size_t))


class Codec(C.Structure):
    _fields_ = [('abi', C.c_int), ('name', C.c_char_p), ('library', C.c_char_p), ('min_level', C.c_int),
                ('max_level', C.c_int), ('bound', BOUND), ('compress', COMP), ('decompress', COMP),
                ('query', QUERY), ('data', DATA)]


def opt(args, k, default, conv=int):
    if k in args:
        i = args.index(k)
        v = conv(args[i + 1])
        del args[i:i + 2]
        return v
    return default


args = sys.argv[1:]
max_bytes = opt(args, '--max-bytes', 4 << 20)
sample = opt(args, '--sample', 0)
threads = opt(args, '--threads', 1)
dumps = opt(args, '--dumps', None, str)
need_refusals = '--need-refusals' in args
if need_refusals:
    args.remove('--need-refusals')
lib = C.CDLL(os.path.abspath(args[0]))
lib.zpaqstd_codecs_v1.restype = C.POINTER(Codec)
lib.zpaqstd_codecs_v1.argtypes = [C.c_int]
lib.zpaqstd_codec_v1.restype = C.POINTER(Codec)
lib.zpaqstd_detect_v1.restype = C.c_int
lib.zpaqstd_detect_v1.argtypes = [C.c_char_p, C.c_char_p, C.c_size_t]
lib.zpaqstd_threads_v1.argtypes = [C.c_int]
lib.zpaqstd_threads_v1(threads)
fails = 0


def fail(msg):
    global fails
    fails += 1
    print('FAIL: ' + msg)
    sys.stdout.flush()


src = open(ARGS_SRC).read()
MAX_PH = int(re.search(r'PPA1_MAX_PH = (\d+);', src).group(1))
MAX_PM = int(re.search(r'PPA1_MAX_PM = (\d+);', src).group(1))
IMAGE_COST = int(re.search(r'PPA1_IMAGE_COST_BYTES = (\d+);', src).group(1))
STATIC_WORDS = int(re.search(r'PPA1_ZPAQL_STATIC_WORDS = (\d+);', open(INC).read()).group(1))
MAX_IMG = int(re.search(r'PPA1_MAX_IMAGE_BYTES = Int64\((\d+)\) shl (\d+);', src).group(1)) << \
    int(re.search(r'PPA1_MAX_IMAGE_BYTES = Int64\((\d+)\) shl (\d+);', src).group(2))

# ---------------------------------------------------------------- the codec's table
codecs = []
while True:
    p = lib.zpaqstd_codecs_v1(len(codecs))
    if not p or len(codecs) > 8:
        break
    codecs.append(p.contents)
names = [c.name.decode() for c in codecs]
if names != ['ppa1']:
    fail('codecs listed: %s, not [ppa1]' % names)
ppa = codecs[0]
if C.addressof(lib.zpaqstd_codec_v1().contents) != C.addressof(ppa):
    fail('zpaqstd_codec_v1 is not ppa1')
if ppa.abi != 1 or ppa.min_level != 1 or ppa.max_level != 1:
    fail('ppa1: abi %d, levels %d..%d' % (ppa.abi, ppa.min_level, ppa.max_level))
if not ppa.library.decode().startswith('ppa1: PPA stream v2, static model'):
    fail('ppa1: library %r' % ppa.library)
size = C.c_size_t(0)
if ppa.data(2, C.byref(size)):
    fail('ppa1 gives its ZPAQL without $3..$5')
z = ppa.data(4, C.byref(size))
cfg = C.string_at(z, size.value) if z else b''
if not cfg.endswith(b'\0'):
    fail('ppa1: its ZPAQL is not given with its NUL')
cfg = cfg.rstrip(b'\0').decode()
if not cfg.startswith('comp 0 0 $3 $4 0 hcomp halt pcomp ppa1 ;') or not cfg.rstrip().endswith('end'):
    fail('ppa1: its ZPAQL config: %r ... %r' % (cfg[:48], cfg[-8:]))
inc = open(INC).read()
part = inc[inc.index('  PPA1_ZPAQL: AnsiString ='):]
part = part[:part.index(';\n')]
want = ''.join(m.replace("''", "'") for m in re.findall(r"^\s+'(.*?)'(?:#10)?\s*\+?$", part, re.M))
if cfg.replace('\n', '') != want.replace('\n', ''):
    fail('ppa1: its ZPAQL is not ppa1zpaql.inc\'s (%d against %d characters)' % (len(cfg), len(want)))
card = ppa.data(3, C.byref(size))
card = C.string_at(card, size.value).decode() if card else ''
for k in ('name=ppa1\n', 'version=', 'author=', 'repo=https://github.com/YadeWira/PPA\n', 'license=MIT\n', 'commit=',
          'format=', 'notes='):
    if k not in card:
        fail('ppa1: its card has no %r' % k)
if ppa.query(3, b'', 0) != 1:
    fail('ppa1: query(ZS_QUERY_SEGMENTS) is not 1')
if ppa.query(2, b'', 0) >= 0 or ppa.query(2, b'\x02\x01\x00', 3) >= 0 or ppa.query(9, b'\x02', 1) >= 0:
    fail('ppa1: query of no stream answered')
if ppa.bound(100, 1) < 100:
    fail('ppa1: bound')

# ---------------------------------------------------------------- what detect must take
SIG_PNG = b'\x89PNG\r\n\x1a\n'
SIG_MNG = b'\x8aMNG\r\n\x1a\n'
SIG_JNG = b'\x8bJNG\r\n\x1a\n'
JNG_CHUNKS = (b'JHDR', b'JDAT', b'JDAA', b'JSEP', b'JdAA')
A7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
NC = {0: 1, 2: 3, 4: 2, 6: 4}


def filtered(w, h, nc, lace):
    if lace == 0:
        return h * (w * nc + 1)
    t = 0
    for x0, y0, dx, dy in A7:
        pw = (w - x0 + dx - 1) // dx if w > x0 else 0
        ph = (h - y0 + dy - 1) // dy if h > y0 else 0
        if pw and ph:
            t += ph * (pw * nc + 1)
    return t


def expect(d):
    """(takes, why): this script's own reading of the chunks (ppapng's walk)"""
    kind = d[:8]
    if kind == SIG_JNG:
        return False, 'jng'
    if kind not in (SIG_PNG, SIG_MNG):
        return False, 'other'
    pos, n = 8, len(d)
    hdr = None          # the current image's IHDR (w, h, nc, lace), or None
    frame = None        # the last fcTL (w, h)
    images = 0
    plain = 0
    widest = 0          # model.zl's lines, in words of H: 5 * (w + 4) * channels
    cur_idat = cur_fdat = False
    refuse = None
    while n - pos >= 12:
        ln = struct.unpack('>I', d[pos:pos + 4])[0]
        if ln > 0x7FFFFFFF or ln > n - pos - 12:
            break
        typ = d[pos + 4:pos + 8]
        if not all(65 <= c <= 90 or 97 <= c <= 122 for c in typ):
            break
        data = d[pos + 8:pos + 8 + ln]
        if typ in JNG_CHUNKS:
            refuse = refuse or 'jng'
        if typ == b'IHDR':
            cur_idat = cur_fdat = False
            frame = None
            if ln < 13 or data[8] != 8 or data[9] not in NC or data[12] > 1:
                refuse = refuse or 'image'
                hdr = None
            else:
                w, h = struct.unpack('>II', data[:8])
                hdr = (w, h, NC[data[9]], data[12])
        elif typ == b'JHDR':
            hdr = None
        elif typ == b'fcTL':
            frame = struct.unpack('>II', data[4:12]) if ln >= 12 else ('bad',)
            cur_fdat = False
        elif typ == b'IDAT' or (typ == b'fdAT' and ln >= 4):
            new = not cur_idat if typ == b'IDAT' else not cur_fdat
            if typ == b'IDAT':
                cur_idat = True
            else:
                cur_fdat = True
            if new:
                if hdr is None:
                    refuse = refuse or 'image'
                else:
                    w, h, nc, lace = hdr
                    if typ == b'fdAT':
                        if frame is None or frame == ('bad',):
                            refuse = refuse or 'image'
                            w = 0
                        else:
                            w, h = frame
                    if w == 0 or h == 0 or w >= 1 << 28 or h >= 1 << 30:
                        refuse = refuse or 'image'
                    else:
                        images += 1
                        plain += filtered(w, h, nc, lace)
                        widest = max(widest, 5 * (w + 4) * nc)
        pos += 12 + ln
        if typ == b'IEND':
            hdr = None
            cur_idat = cur_fdat = False
            frame = None
            if kind != SIG_MNG:
                break
        if typ == b'MEND':
            break
    if refuse:
        return False, refuse
    if images == 0:
        return False, 'no image'
    if plain + IMAGE_COST * images > MAX_IMG:
        return False, 'size'
    # the widest image's lines alone past PPA1_MAX_PH (the records, a few
    # words a chunk, left out: no file here is near that edge)
    if lg(STATIC_WORDS + widest) > MAX_PH:
        return False, 'size'
    return True, ''


def lg(n):
    k = 0
    while (1 << k) < n:
        k += 1
    return k


needs_of = None
if dumps:
    sys.path.insert(0, os.path.join(REPO, 'tools', 'zpaql'))
    import json
    import test_ppadec
    sw = test_ppadec.static_words()

    def needs_of(name, seglen):
        jp = os.path.join(dumps, name + '.json')
        if not os.path.exists(jp):
            return None
        j = json.load(open(jp))
        if not test_ppadec.taken(j):
            return None
        hw, mb = test_ppadec.needs(dumps, name, j, seglen, sw)
        return lg(hw), lg(mb), open(os.path.join(dumps, name + '.stream'), 'rb').read()


def roundtrip(d, label):
    """compress, query, decompress; the query's $3, $4"""
    cap = ppa.bound(len(d), 1)
    out = C.create_string_buffer(cap)
    n = ppa.compress(d, len(d), out, cap, 1)
    if n < 0:
        fail('%s: compress %d' % (label, n))
        return None
    s = out.raw[:n]
    a = ppa.query(2, s, n)
    ph, pm = a & 255, (a >> 8) & 255
    if a < 0 or a >> 16 or ph > MAX_PH or pm > MAX_PM or ph < 21:
        fail('%s: query %d' % (label, a))
        return None
    back = C.create_string_buffer(len(d) + 1)
    m = ppa.decompress(s, n, back, len(d), 0)
    if m != len(d) or back.raw[:m] != d:
        fail('%s: decompress %d' % (label, m))
        return None
    # one byte too few for the original: refused
    if len(d) > 0 and ppa.decompress(s, n, back, len(d) - 1, 0) >= 0:
        fail('%s: decompress into one byte less' % label)
    return s, ph, pm


files_by_dir = []
for a in args[1:]:
    if os.path.isdir(a):
        fs = sorted(os.path.join(a, f) for f in os.listdir(a) if os.path.isfile(os.path.join(a, f)))
        files_by_dir.append((a, fs))
    else:
        files_by_dir.append((a, [a]))

tot_taken = tot_refused_kinds = 0
refusals = {}
biggest = []
summary = []
for dname, fs in files_by_dir:
    taken = []
    for f in fs:
        d = open(f, 'rb').read()
        want, why = expect(d)
        det = lib.zpaqstd_detect_v1(b'ppa1', d, len(d))
        if lib.zpaqstd_detect_v1(b'ppa', d, len(d)) or lib.zpaqstd_detect_v1(b'pja', d, len(d)):
            fail('%s: detect takes it for another codec name' % f)
        if det != int(want):
            fail('%s: detect says %d (expected %d%s)' % (f, det, want, ', ' + why if why else ''))
        if not det:
            refusals[why] = refusals.get(why, 0) + 1
            continue
        taken.append((f, d))
    tot_taken += len(taken)
    cand = [(f, d) for f, d in taken if len(d) <= max_bytes]
    if sample and len(cand) > sample:
        cand = [cand[(i * len(cand)) // sample] for i in range(sample)]
    back = 0
    for f, d in cand:
        name = os.path.basename(f)
        r = roundtrip(d, name)
        if r is None:
            continue
        s, ph, pm = r
        back += 1
        biggest.append((pm, ph, len(d), name))
        if needs_of:
            nd = needs_of(name, 4 + len(s))
            if nd is not None:
                if nd[2] != s:
                    fail('%s: the stream is not the dump\'s' % name)
                elif (nd[0], nd[1]) != (ph, pm):
                    fail('%s: query H 2^%d M 2^%d, test_ppadec.needs() says H 2^%d M 2^%d' % (name, ph, pm, nd[0], nd[1]))
        # with zpaq-std's list of fragments after it (one fragment: its size,
        # then 4 bytes and the count 1): compressed, the bytes come back
        if f == cand[0][0]:
            frag = struct.pack('<I', len(d)) + b'\0\0\0\0' + struct.pack('<I', 1)
            if roundtrip(d + frag, name + ' + fragment list') is None:
                continue
            # a damaged stream: refused or other bytes, never a crash
            cap = ppa.bound(len(d), 1)
            out = C.create_string_buffer(cap)
            n = ppa.compress(d, len(d), out, cap, 1)
            sb = bytearray(out.raw[:n])
            bad = C.create_string_buffer(len(d) + 1)
            for k in range(0, n, max(1, n // 64)):
                t = bytearray(sb)
                t[k] ^= 0x55
                ppa.decompress(bytes(t), n, bad, len(d), 0)
                ppa.query(2, bytes(t), n)
            for cut in (1, n // 3, n - 1):
                ppa.decompress(bytes(sb[:cut]), cut, bad, len(d), 0)
                ppa.query(2, bytes(sb[:cut]), cut)
    summary.append('%s: %d files, ppa1 took %d, %d back through compress, query and decompress' % (
        os.path.basename(os.path.normpath(dname)), len(fs), len(taken), back))
for line in summary:
    print('  ' + line)
biggest.sort(reverse=True)
for pm, ph, n, name in biggest[:5]:
    print('  query H 2^%d M 2^%d: %s (%d bytes)' % (ph, pm, name, n))
print('  refused: ' + ', '.join('%s %d' % kv for kv in sorted(refusals.items())))
if need_refusals and (not refusals.get('image') or not refusals.get('jng')):
    fail('no palette / 16-bit or JNG file refused: the suite needs some')
print('plugin: 1 codec, ppa1 (ZPAQL %d bytes of text); %d files taken, %d failures' % (len(cfg), tot_taken, fails))
sys.exit(1 if fails else 0)
