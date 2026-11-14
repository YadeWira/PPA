#!/usr/bin/env python3
"""Build the preflate test corpus under $PF/corpus (README.md), one folder per
subset, each with a MANIFEST.tsv (file, kind, origin, encoder, version,
settings, bytes, sha256, note).

    python3 tools/preflate/mkcorpus.py png|synth|raw|pda|hostile|zflow|all [-j N]

Needs the tools build_tools.sh makes. Everything is copied: nothing is ever
written to /mnt/OSR_D3 or to the study folders. Running it again rebuilds a
subset from scratch; the outputs are deterministic except where a tool is not
(none found so far: the manifests' sha256 are the check)."""
import json, os, re, shutil, struct, subprocess, sys, tempfile, zlib
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pfcommon import *

JOBS = 4
CENSUS = os.path.join(STUDY, 'encoder-census', 'work')
VERS = {}


def versions():
    p = os.path.join(TOOLS, 'VERSIONS.tsv')
    for line in open(p).read().splitlines()[1:]:
        t, v, _ = line.split('\t')
        VERS[t] = v
    return VERS


def fresh(sub):
    d = os.path.join(CORPUS, sub)
    if os.path.isdir(d):
        shutil.rmtree(d)
    os.makedirs(d)
    return d


def pmap(f, items):
    with ThreadPoolExecutor(JOBS) as ex:
        return [r for r in ex.map(f, items)]


# ---------------------------------------------------------------- png-zlib, png-nonzlib

def zlib_settings(streams):
    seen = []
    for s in streams:
        z = s.get('zlib')
        t = 'L%d %s ml%d w%d' % (z['level'], z['strategy'], z['memLevel'], z['wbits']) if z else '?'
        if t not in seen:
            seen.append(t)
    return ', '.join(seen) if seen else 'no deflate stream'


NONZLIB = [  # (pattern, encoder, version, settings, note) from report1's fingerprints
    (r'like-doodleAtari|arrowdwn', 'miniz', '<=1.x (78 01 header; 1.14 matches)', 'L9 (tdefl, non-greedy)',
     'exact bit match with miniz 1.14 tdefl_compress_mem_to_heap L9 (census fam2/fam3)'),
    (r'spider', 'unidentified', '?', '?', 'nearest miniz L10 93.7-97.5% of tokens; not zlib/libdeflate/zopfli/7z/Go/lodepng'),
    (r'ipad', 'zlib', '1.3.1-compatible', 'L9 filtered ml8|9 w15 + Z_FULL_FLUSH at plain 10404 (row 36 of 72)',
     'Apple CgBI, bare deflate; dynamic, empty stored, dynamic'),
    (r'_oxipng', 'libdeflate (oxipng)', '1.23', 'L11', 'exact bit match with libdeflate 1.23 L11'),
]


def do_png():
    zdir, ndir = fresh('png-zlib'), fresh('png-nonzlib')
    zrows, nrows = [], []
    for line in open(os.path.join(CENSUS, 'census.jsonl')):
        r = json.loads(line)
        set_, name = r['file'].split('/', 1)
        src = os.path.join(CENSUS, 'corpus', name) if set_ == 'corpus' else os.path.join(SETS, 'generated', name)
        if set_ == 'corpus':
            origin = os.path.join(OSR, name.replace('__', '/'))
            if not os.path.exists(origin) or sha256(origin) != sha256(src):
                raise SystemExit('origin differs: ' + origin)
        else:
            origin = os.path.join(SETS, 'generated', name) + ' (tools/bench/mkgen.py)'
        reproduced = all(s.get('zlib') for s in r['streams'])
        dst = ('corpus__' if set_ == 'corpus' else 'generated__') + name
        if reproduced:
            shutil.copyfile(src, os.path.join(zdir, dst))
            zrows.append(dict(file=dst, kind=r['fmt'].lower(), origin=origin, encoder='zlib',
                              version='1.3.1-compatible', settings=zlib_settings(r['streams']),
                              note='%d image streams; parameters: the first set the census search matched' % len(r['streams'])))
        else:
            for pat, enc, ver, st, note in NONZLIB:
                if re.search(pat, name):
                    break
            else:
                raise SystemExit('unclassified ' + name)
            shutil.copyfile(src, os.path.join(ndir, dst))
            nrows.append(dict(file=dst, kind=r['fmt'].lower() + ('-cgbi' if r['cgbi'] else ''), origin=origin,
                              encoder=enc, version=ver, settings=st, note=note))
    print('png-zlib', write_manifest(zdir, zrows), 'png-nonzlib', write_manifest(ndir, nrows))


# ---------------------------------------------------------------- png-synth

# ~34 sources: kinds of image a PNG writer sees (photo, palette, 1/2-bit,
# 16-bit, gray, gray+alpha, RGBA, interlaced, screenshot-like, gradient, flat,
# noise). Synthetic ones are made here, deterministic.
SOURCES = [
    ('photos/0028B2CCB.png', 'photo 1920x1200 RGB'), ('photos/14133618F.png', 'photo 1280x800 RGB'),
    ('photos/22FF15A7E.png', 'photo 1366x768 RGB'), ('photos/3A5AEFB06.png', 'photo 1920x1080 RGB'),
    ('corpus/image__png__JUDGE.png', '1-bit gray'), ('corpus/image__png__itoa_7p2.png', '1-bit gray 1500x1500'),
    ('corpus/image__png__input_bw.png', '1-bit gray small'), ('corpus/image__png__input_16.png', '16-bit gray'),
    ('corpus/image__png__input_256.png', 'palette small'), ('corpus/image__png__input_mono.png', 'gray small'),
    ('corpus/image__png__input_truecolor.png', 'RGB small'), ('corpus/image__png__diagram.png', 'diagram/screenshot RGB'),
    ('corpus/image__png__antiqhvy.png', 'RGBA art 2331x623'), ('corpus/image__lottie__images__img_0.png', 'RGBA icon'),
    ('corpus/unknown__image__like-championsInterlace__VVMTITLE.png', '2-bit palette'),
    ('corpus/unknown__image__like-championsInterlace__ANIMALS.png', '1-bit palette'),
    ('corpus/image__png__abydos.png', 'RGBA 800x600'), ('corpus/unknown__image__like-doodleAtari__BIRD1.png', 'gray 640x400 (miniz source)'),
    ('generated/photo_16bit.png', '16-bit RGB photo'), ('generated/photo_gray.png', 'gray photo'),
    ('generated/photo_adam7.png', 'interlaced RGB photo'), ('generated/graphic_adam7.png', 'interlaced graphic'),
    ('generated/graphic_pal256.png', 'palette graphic'), ('generated/icon_pal256.png', 'palette icon'),
    ('generated/rgba_base.png', 'RGBA'), ('generated/icon_base.png', 'RGBA icon'),
    ('generated/art_base.png', 'gray+alpha art'), ('generated/graphic_base.png', 'RGB graphic'),
    ('generated/rgba_gray.png', 'gray+alpha'), ('generated/photo_pal256.png', 'palette photo'),
    ('@gradient', 'synthetic RGB gradient 1024x768'), ('@ui', 'synthetic screenshot-like 1280x800'),
    ('@flat', 'synthetic flat 2048x2048 RGB (long runs)'), ('@noise', 'synthetic noise 256x256 RGB (stored blocks)'),
]


def make_png(path, w, h, ct, rows):
    """rows: filtered scanlines (filter byte included); zlib 1.3.1 L6"""
    raw = b''.join(rows)
    d = SIG + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, ct, 0, 0, 0)) + \
        chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b'')
    open(path, 'wb').write(d)


def synth_source(kind, path):
    if kind == '@gradient':
        w, h = 1024, 768
        rows = [b'\x00' + bytes(v for x in range(w) for v in ((x * 255) // w, (y * 255) // h, ((x + y) * 255) // (w + h)))
                for y in range(h)]
        make_png(path, w, h, 2, rows)
    elif kind == '@ui':
        w, h = 1280, 800
        rows = []
        for y in range(h):
            line = bytearray()
            for x in range(w):
                if y < 40: c = (40, 44, 52)
                elif x < 220: c = (245, 245, 245) if (y // 24) % 2 else (235, 235, 240)
                elif (y % 20) in (6, 7, 8, 9, 10, 11) and ((x * 7 + (y // 20) * 13) % 97) < 60 and x < 1100:
                    c = (20, 20, 20) if ((x * 31 + y * 17) % 5) < 3 else (90, 90, 200)
                else: c = (255, 255, 255)
                line += bytes(c)
            rows.append(b'\x00' + bytes(line))
        make_png(path, w, h, 2, rows)
    elif kind == '@flat':
        w, h = 2048, 2048
        rows = [b'\x00' + bytes((30, 60, 90)) * w if y < 1500 else b'\x00' + bytes((200, 10, 10)) * w for y in range(h)]
        make_png(path, w, h, 2, rows)
    elif kind == '@noise':
        import random
        rnd = random.Random(20261113)
        w, h = 256, 256
        rows = [b'\x00' + bytes(rnd.getrandbits(8) for _ in range(3 * w)) for _ in range(h)]
        make_png(path, w, h, 2, rows)


def zflush_events(plain, rb):
    """the zfl scripts: (name, level, memLevel, strategy, events)"""
    n = len(plain); rows = n // rb
    at = lambda k: min(n, k * rb)  # after row k
    every = lambda k, what: ['%d:%s' % (at(i), what) for i in range(k, rows, k)]
    return [
        ('zfl-L6-sync16', 6, 8, 0, every(16, 'sync')),
        ('zfl-L9f-full-half', 9, 8, 1, ['%d:full' % at(rows // 2)]),
        ('zfl-L6-partial32', 6, 8, 0, every(32, 'partial')),
        ('zfl-L9-block3', 9, 8, 0, ['%d:block' % at(rows // 3), '%d:block' % at(2 * rows // 3)]),
        ('zfl-L1-sync8-ml7', 1, 7, 0, every(8, 'sync')),
        ('zfl-L6to1-params', 6, 8, 0, ['%d:params=1,0' % at(rows // 2)]),
        ('zfl-L9to-filtered-params', 9, 8, 0, ['%d:params=9,1' % at(rows // 3)]),
        ('zfl-L1to9-params', 1, 8, 0, ['%d:params=9,0' % at(rows // 2)]),
        ('zfl-L6-mixed', 6, 8, 0, ['%d:sync' % at(rows // 4), '%d:full' % at(rows // 2), '%d:partial' % at(3 * rows // 4)]),
    ]


RAW_ENCODERS = [  # rewraps of the source's own filtered bytes: name, cmd(in) -> raw deflate, version key, level hint
    ('libdeflate-1', lambda i: [BIN + '/ldf', i, '1'], 'ldf', 1),
    ('libdeflate-6', lambda i: [BIN + '/ldf', i, '6'], 'ldf', 6),
    ('libdeflate-9', lambda i: [BIN + '/ldf', i, '9'], 'ldf', 9),
    ('libdeflate-12', lambda i: [BIN + '/ldf', i, '12'], 'ldf', 9),
    ('miniz114-9', lambda i: [BIN + '/mz114', i, '9'], 'mz114', 0),   # miniz 1.x writes 78 01
    ('miniz3-1', lambda i: [BIN + '/mz3', i, '1'], 'mz3', 1),
    ('miniz3-6', lambda i: [BIN + '/mz3', i, '6'], 'mz3', 6),
    ('miniz3-10', lambda i: [BIN + '/mz3', i, '10'], 'mz3', 9),
    ('zlibng-1', 'zng1', 'zlib-ng', 1), ('zlibng-6', 'zng6', 'zlib-ng', 6), ('zlibng-9', 'zng9', 'zlib-ng', 9),
    ('zopfli-15', lambda i: [BIN + '/zop', i, '15'], 'zopfli/zopflipng/zop', 9),
    ('7z-gzip-mx9', '7z9', '7zz', 9),
]
RAW_SOURCES = 10   # the first sources of each kind that get every raw encoder
BIG = 2 << 20      # plain bytes above which zopfli-based tools run 1 iteration


def raw_encode(how, plain_path, tmp):
    if isinstance(how, str) and how.startswith('zng'):
        env = dict(os.environ)
        code = ('import sys;sys.path.insert(0,%r);from zlib_ng import zlib_ng as z;d=open(sys.argv[1],"rb").read();'
                'c=z.compressobj(%s,z.DEFLATED,-15);sys.stdout.buffer.write(c.compress(d)+c.flush())' % (os.path.join(TOOLS, 'pylib'), how[3:]))
        return subprocess.run(['python3', '-I', '-c', code, plain_path], env=env, check=True, capture_output=True).stdout
    if how == '7z9':
        gz = os.path.join(tmp, 's.gz')
        if os.path.exists(gz): os.remove(gz)
        subprocess.run(['7zz', 'a', '-tgzip', '-mx=9', gz, plain_path], check=True, capture_output=True)
        g = open(gz, 'rb').read()
        flg = g[3]; p = 10
        if flg & 4: p += 2 + struct.unpack('<H', g[p:p + 2])[0]
        if flg & 8: p = g.index(b'\0', p) + 1
        if flg & 16: p = g.index(b'\0', p) + 1
        if flg & 2: p += 2
        return deflate_body(g[p:])[0]
    return subprocess.run(how(plain_path), check=True, capture_output=True).stdout


def synth_one(job):
    """job: (index, source path, description, out dir) -> manifest rows"""
    k, src, desc, out = job
    rows = []
    base = 's%02d' % k
    tmp = tempfile.mkdtemp(dir=os.path.join(PF, 'tmp'))
    try:
        info = ihdr(src); plain = idat_plain(src); rb = row_bytes(info) if not info['il'] else None
        plain_path = os.path.join(tmp, 'plain'); open(plain_path, 'wb').write(plain)
        big = len(plain) > BIG
        srcstream = b''.join(b for t, b in chunks(open(src, 'rb').read())[0] if t == b'IDAT')
        seen = {sha256(srcstream)}

        def keep(name, path, enc, ver, settings, note=''):
            try:
                ch, _ = chunks(open(path, 'rb').read())
                st = b''.join(b for t, b in ch if t == b'IDAT')
                if not st: raise ValueError('no IDAT')
            except Exception as e:
                print('  drop', base, name, e, file=sys.stderr)
                os.remove(path); return
            h = sha256(st)
            if h in seen:
                os.remove(path); return   # the tool kept the source's stream, or another's: not new
            seen.add(h)
            rows.append(dict(file=os.path.basename(path), kind='png', origin=src, encoder=enc,
                             version=VERS.get(ver, ver), settings=settings, note=(desc + '; ' + note).strip('; ')))

        def tool(name, cmd, enc, ver, settings, inplace=False, note=''):
            dst = os.path.join(out, '%s.%s.png' % (base, name))
            try:
                if inplace:
                    shutil.copyfile(src, dst); subprocess.run(cmd + [dst], check=True, capture_output=True, timeout=3600)
                else:
                    subprocess.run([c.replace('@OUT', dst) for c in cmd], check=True, capture_output=True, timeout=3600)
            except Exception as e:
                print('  skip', base, name, type(e).__name__, file=sys.stderr)
                if os.path.exists(dst): os.remove(dst)
                return
            if os.path.exists(dst): keep(name, dst, enc, ver, settings, note)

        zi = ['--zi', '1'] if big else []
        for o in ['0', '2', '4', 'max']:
            tool('oxipng-o' + o, ['oxipng', '-q', '--force', '-o', o, '--out', '@OUT', src], 'oxipng (libdeflate)', 'oxipng', '-o ' + o)
        tool('oxipng-o2-zopfli', ['oxipng', '-q', '--force', '-o', '2', '-z'] + zi + ['--out', '@OUT', src],
             'oxipng (zopfli)', 'oxipng', '-o 2 -z ' + ' '.join(zi))
        it = ['--iterations=1'] if big else []
        tool('zopflipng', [BIN + '/zopflipng', '-y', '--always_zopflify', '--keepcolortype'] + it + [src, '@OUT'],
             'zopflipng', 'zopfli/zopflipng/zop', '--always_zopflify --keepcolortype ' + ' '.join(it))
        for m in ['1', '4', '7', '113', '124']:
            tool('pngcrush-m' + m, [BIN + '/pngcrush', '-q', '-force', '-m', m, src, '@OUT'], 'pngcrush (zlib 1.2.11)', 'pngcrush', '-m ' + m)
        for z in ['1', '2', '3', '4']:
            extra = ['-i', '1'] if (big and z in '34') else []
            tool('advpng-z' + z, [BIN + '/advpng', '-q', '-f', '-z', '-' + z] + extra, 'advpng', 'advpng',
                 '-z -%s %s' % (z, ' '.join(extra)), inplace=True,
                 note={'1': 'zlib', '2': 'libdeflate', '3': '7-Zip deflate', '4': 'zopfli'}[z])
        tool('optipng-o2', ['optipng', '-quiet', '-force', '-o2', '-out', '@OUT', src], 'optipng (zlib)', 'optipng', '-o2 -force')
        # zlib with flushes and parameter changes, on the source's own filtered bytes
        if rb:
            for name, lv, ml, st, ev in zflush_events(plain, rb):
                raw = subprocess.run([BIN + '/zfl', plain_path, str(lv), str(ml), '-15', str(st)] + ev,
                                     check=True, capture_output=True).stdout
                dst = os.path.join(out, '%s.%s.png' % (base, name))
                rewrap_png(src, zlib_wrap(raw, plain, lv), dst)
                keep(name, dst, 'zlib (zfl)', 'zfl', 'L%d ml%d s%d w15 events %s' % (lv, ml, st, ' '.join(ev) if len(ev) <= 4
                     else '%s .. (%d)' % (' '.join(ev[:3]), len(ev))))
        if k < RAW_SOURCES or SOURCES[k][0].startswith('@'):
            for name, how, ver, hint in RAW_ENCODERS:
                if name.startswith('zopfli') and big: continue
                raw = raw_encode(how, plain_path, tmp)
                dst = os.path.join(out, '%s.%s.png' % (base, name))
                rewrap_png(src, zlib_wrap(raw, plain, hint), dst)
                keep(name, dst, name.rsplit('-', 1)[0], ver, 'raw deflate of the source IDAT bytes, level ' + name.rsplit('-', 1)[1],
                     'zlib header for FLEVEL of level %d' % hint)
    finally:
        shutil.rmtree(tmp)
    print('  %s %-58s %d files' % (base, os.path.basename(src), len(rows)), flush=True)
    return rows


def do_synth():
    out = fresh('png-synth'); sdir = os.path.join(out, 'sources'); os.makedirs(sdir)
    os.makedirs(os.path.join(PF, 'tmp'), exist_ok=True)
    jobs = []; srows = []
    for k, (rel, desc) in enumerate(SOURCES):
        if rel.startswith('@'):
            dst = os.path.join(sdir, 's%02d.%s.png' % (k, rel[1:]))
            synth_source(rel, dst); origin = 'made by mkcorpus.py (%s)' % rel
        else:
            dst = os.path.join(sdir, 's%02d.%s' % (k, os.path.basename(rel)))
            shutil.copyfile(os.path.join(SETS, rel), dst); origin = os.path.join(SETS, rel)
        srows.append(dict(file=os.path.basename(dst), kind='png', origin=origin, encoder='(source)', version='',
                          settings='', note=desc))
        jobs.append((k, dst, desc, out))
    write_manifest(sdir, srows)
    rows = [r for rs in pmap(synth_one, jobs) for r in rs]
    print('png-synth', write_manifest(out, rows), 'files from', len(jobs), 'sources')


# ---------------------------------------------------------------- raw

def do_raw():
    out = fresh('raw'); A = os.path.join(STUDY, 'algorithm')
    pdir = os.path.join(out, 'plain'); os.makedirs(pdir)
    rows = []; prow = []
    # the study's streams, so that preflate's figures compare cell by cell with report0 section 2
    study_enc = {'zlib1': ('zlib', 'python-zlib', 'L1'), 'zlib6': ('zlib', 'python-zlib', 'L6'), 'zlib9': ('zlib', 'python-zlib', 'L9'),
                 'gnugzip9': ('GNU gzip', 'gzip', '-9'), 'libdeflate1': ('libdeflate', 'libdeflate 1.26 (study)', '1'),
                 'libdeflate6': ('libdeflate', 'libdeflate 1.26 (study)', '6'), 'libdeflate9': ('libdeflate', 'libdeflate 1.26 (study)', '9'),
                 'libdeflate12': ('libdeflate', 'libdeflate 1.26 (study)', '12'), 'zopfli': ('zopfli', 'git df1517d', '15 iterations'),
                 '7z5': ('7-Zip gzip', '7zz', '-mx5'), '7z9': ('7-Zip gzip', '7zz', '-mx9')}
    for f in sorted(os.listdir(os.path.join(A, 'work'))):
        m = re.fullmatch(r'(text|exe|bmp)\.(\w+)', f)
        if not m: continue
        enc, ver, st = study_enc[m.group(2)]
        shutil.copyfile(os.path.join(A, 'work', f), os.path.join(out, f + '.raw'))
        rows.append(dict(file=f + '.raw', kind='raw', origin=os.path.join(A, 'work', f), encoder=enc,
                         version=VERS.get(ver, ver), settings=st, note='plain: plain/%s.bin (report0 section 2)' % m.group(1)))
    for f in ['text', 'exe', 'bmp']:
        shutil.copyfile(os.path.join(A, 'data', f + '.bin'), os.path.join(pdir, f + '.bin'))
        prow.append(dict(file=f + '.bin', kind='plain', origin=os.path.join(A, 'data', f + '.bin'), note='report0 sample'))
    for f in ['big.7z9', 'big.zlib9']:
        shutil.copyfile(os.path.join(A, 'big', f), os.path.join(out, 'ecoli.' + f.split('.')[1] + '.raw'))
        rows.append(dict(file='ecoli.%s.raw' % f.split('.')[1], kind='raw', origin=os.path.join(A, 'big', f),
                         encoder='7-Zip gzip' if '7z' in f else 'zlib', version=VERS['7zz'] if '7z' in f else '1.3.1',
                         settings='-mx9' if '7z' in f else 'L9', note='plain: algorithm/big/big.bin (ecoli.gbk, 12.9 MB), not copied'))
    # every libdeflate level and the other encoders, on the text, exe and bmp samples
    os.makedirs(os.path.join(PF, 'tmp'), exist_ok=True)
    tmp = tempfile.mkdtemp(dir=os.path.join(PF, 'tmp'))
    more = [('ldf%d' % l, lambda i, l=l: [BIN + '/ldf', i, str(l)], 'libdeflate', 'ldf', str(l)) for l in range(0, 13)]
    more += [('mz114-9', lambda i: [BIN + '/mz114', i, '9'], 'miniz', 'mz114', 'L9'),
             ('mz3-1', lambda i: [BIN + '/mz3', i, '1'], 'miniz', 'mz3', 'L1'),
             ('mz3-6', lambda i: [BIN + '/mz3', i, '6'], 'miniz', 'mz3', 'L6'),
             ('mz3-10', lambda i: [BIN + '/mz3', i, '10'], 'miniz', 'mz3', 'L10'),
             ('zng1', 'zng1', 'zlib-ng', 'zlib-ng', 'L1'), ('zng6', 'zng6', 'zlib-ng', 'zlib-ng', 'L6'),
             ('zng9', 'zng9', 'zlib-ng', 'zlib-ng', 'L9')]
    for f in ['text', 'exe', 'bmp']:
        src = os.path.join(pdir, f + '.bin')
        for name, how, enc, ver, st in more:
            raw = raw_encode(how, src, tmp)
            open(os.path.join(out, '%s.%s.raw' % (f, name)), 'wb').write(raw)
            rows.append(dict(file='%s.%s.raw' % (f, name), kind='raw', origin='plain/%s.bin' % f, encoder=enc,
                             version=VERS.get(ver, ver), settings=st, note=''))
        # zlib with flushes, raw: a sync every 64 KiB, a full flush in the middle
        n = os.path.getsize(src)
        for name, ev in [('zfl-L6-sync64k', ['%d:sync' % p for p in range(65536, n, 65536)]),
                         ('zfl-L9-full-half', ['%d:full' % (n // 2)])]:
            lv = name.split('-')[1][1:]
            raw = subprocess.run([BIN + '/zfl', src, lv, '8', '-15', '0'] + ev, check=True, capture_output=True).stdout
            open(os.path.join(out, '%s.%s.raw' % (f, name)), 'wb').write(raw)
            rows.append(dict(file='%s.%s.raw' % (f, name), kind='raw', origin='plain/%s.bin' % f, encoder='zlib (zfl)',
                             version=VERS['zfl'], settings='L%s ml8 %s' % (lv, ev[0] if len(ev) == 1 else 'sync every 65536'), note=''))
    shutil.rmtree(tmp)
    write_manifest(pdir, prow)
    print('raw', write_manifest(out, rows))


# ---------------------------------------------------------------- pda

PDA = os.path.join(STUDY, 'pda-census')
OBJ = re.compile(rb'(\d+)\s+(\d+)\s+obj\b')
STRM = re.compile(rb'stream(\r\n|\n|\r)')


def pdf_streams(b):
    """the FlateDecode stream candidates of a PDF in census3's order: (start, data window)"""
    for sm in STRM.finditer(b):
        st = sm.end()
        pre = b[max(0, sm.start() - 4096):sm.start()]
        if not pre.rstrip().endswith(b'>>'): continue
        om = None
        for om in OBJ.finditer(pre): pass
        dct = pre[om.end():] if om else pre[-1024:]
        f = re.search(rb'/Filter\s*(\[\s*)?/(\w+)', dct)
        if not f or f.group(2) not in (b'FlateDecode', b'Fl'): continue
        lm = re.search(rb'/Length\s+(\d+)\b(?!\s+\d+\s+R)', dct)
        e = b.find(b'endstream', st)
        end = st + int(lm.group(1)) if lm else (e if e > 0 else len(b))
        if lm and (end > len(b) or (e > 0 and end > e + 2)): end = e if e > 0 else len(b)
        yield b[st:end + 64]


def zip_streams(b):
    i = b.rfind(b'PK\x05\x06', max(0, len(b) - 70000))
    if i < 0: return
    n, cdoff = struct.unpack('<H', b[i + 10:i + 12])[0], struct.unpack('<I', b[i + 16:i + 20])[0]
    p = cdoff
    for _ in range(n):
        if b[p:p + 4] != b'PK\x01\x02': break
        meth, cs = struct.unpack('<H', b[p + 10:p + 12])[0], struct.unpack('<I', b[p + 20:p + 24])[0]
        fnl, exl, cml = struct.unpack('<HHH', b[p + 28:p + 34]); lho = struct.unpack('<I', b[p + 42:p + 46])[0]
        name = b[p + 46:p + 46 + fnl]
        p += 46 + fnl + exl + cml
        if b[lho:lho + 4] != b'PK\x03\x04': continue
        lf, le = struct.unpack('<HH', b[lho + 26:lho + 30])
        s = lho + 30 + lf + le
        yield name.decode('utf-8', 'replace'), meth, b[s:s + cs]


def pda_creator(r):
    c = r.get('creator') or {}
    return (c.get('app') or c.get('Producer') or c.get('Creator') or c.get('generator') or 'unknown')[:60]


def do_pda(target=300):
    out = fresh('pda')
    allr = [json.loads(l) for l in open(os.path.join(PDA, 'census3.jsonl'))]
    usable = [i for i, r in enumerate(allr) if r.get('inflate_ok') and not r.get('skip') and r.get('cs')]
    # stratify: every creator group, misses first (they are what M2/M3 work on), streams with
    # flushes, the largest and a median match; then small streams (PDA's median is about 500 B)
    import collections
    groups = collections.defaultdict(list)
    for i in usable:
        groups[(allr[i]['kind'], pda_creator(allr[i]))].append(i)
    picked = set()
    for g in sorted(groups):
        idx = groups[g]
        miss = sorted([i for i in idx if not allr[i].get('match')], key=lambda i: (-allr[i]['cs'], i))
        hit = sorted([i for i in idx if allr[i].get('match')], key=lambda i: (-allr[i]['cs'], i))
        ev = [i for i in hit if allr[i].get('nevents')]
        picked.update(miss[:6] + ev[:3] + hit[:2] + hit[len(hit) // 2:len(hit) // 2 + 1])
    rest = [i for i in usable if i not in picked and allr[i]['cs'] < 1000]
    step = max(1, len(rest) // max(1, target - len(picked)))
    for i in rest[::step]:
        if len(picked) >= target: break
        picked.add(i)
    by_file = collections.defaultdict(list)
    for i in sorted(picked): by_file[allr[i]['file']].append(i)
    rows = []
    for path, idx in sorted(by_file.items()):
        b = open(path, 'rb').read()
        if allr[idx[0]]['kind'] == 'zip':
            ents = {}
            for name, meth, data in zip_streams(b):
                if meth == 8: ents.setdefault(name, data)
            for i in idx:
                r = allr[i]; data = ents.get(r['name'])
                if data is None or len(data) < r['cs']: raise SystemExit('zip entry not found: %s %s' % (path, r['name']))
                body, plain, _ = deflate_body(data[:r['cs']])
                if len(plain) != r['us']: raise SystemExit('zip entry differs: %s %s' % (path, r['name']))
                fn = 'z%05d.raw' % i
                open(os.path.join(out, fn), 'wb').write(body)
                rows.append(pda_row(fn, r, path, 'raw', 'zip entry ' + r['name']))
        else:
            # census3 has one record per FlateDecode candidate of at least 2 bytes, in file order
            lines = [k for k, r in enumerate(allr) if r['file'] == path and r['kind'] == 'pdf' and not r.get('nostreams')]
            cand = [d for d in pdf_streams(b) if len(d) >= 2]
            if len(lines) != len(cand): raise SystemExit('pdf candidates differ: %s %d %d' % (path, len(lines), len(cand)))
            for i in idx:
                r = allr[i]; d = cand[lines.index(i)]
                body, plain, hdr = deflate_body(d)
                if len(plain) != r['us']: raise SystemExit('pdf stream differs: %s line %d' % (path, i))
                if hdr:
                    fn = 'p%05d.z' % i
                    open(os.path.join(out, fn), 'wb').write(d[:2 + len(body) + 4])
                else:
                    fn = 'p%05d.raw' % i
                    open(os.path.join(out, fn), 'wb').write(body)
                rows.append(pda_row(fn, r, path, 'zlib' if hdr else 'raw',
                                    'pdf stream %d (%s %s)' % (lines.index(i), r.get('type'), r.get('subtype'))))
    print('pda', write_manifest(out, rows), 'streams from', len(by_file), 'files')


def pda_row(fn, r, path, kind, where):
    m = r.get('match')
    ev = r.get('evkinds') or ''
    return dict(file=fn, kind=kind, origin='%s :: %s' % (path, where), encoder='zlib' if m else 'not zlib (census3)',
                version='1.3.1' if m else '', settings=('L%s %s ml%s w%s' % tuple(m) + (' flushes:' + ev if ev else '')) if m else '',
                note='creator=%s; cs=%d us=%d' % (pda_creator(r), r['cs'], r['us']))


# ---------------------------------------------------------------- hostile

def do_hostile():
    out = fresh('hostile'); rows = []

    def put(name, data, what, note=''):
        open(os.path.join(out, name), 'wb').write(data)
        rows.append(dict(file=name, kind='raw' if name.endswith('.raw') else 'zlib', origin='made by mkcorpus.py', encoder='crafted',
                         settings=what, note=note))

    def bits(fields):
        """fields: [(value, nbits)] LSB first -> bytes"""
        acc = n = 0; o = bytearray()
        for v, k in fields:
            acc |= v << n; n += k
            while n >= 8: o.append(acc & 255); acc >>= 8; n -= 8
        if n: o.append(acc & 255)
        return bytes(o)

    def zfl(plain, *a):
        p = os.path.join(out, '.in'); open(p, 'wb').write(plain)
        r = subprocess.run([BIN + '/zfl', p] + list(a), check=True, capture_output=True).stdout
        os.remove(p); return r

    def ldf(plain, level):
        p = os.path.join(out, '.in'); open(p, 'wb').write(plain)
        r = subprocess.run([BIN + '/ldf', p, str(level)], check=True, capture_output=True).stdout
        os.remove(p); return r

    # long runs of zeros: chain walks and the zlib deflate_slow cost
    z64 = bytes(64 << 20)
    put('zeros64m.L9.raw', zfl(z64, '9', '8', '-15', '0'), '64 MiB of zeros, zlib L9', 'quadratic chains')
    put('zeros64m.L1.raw', zfl(z64, '1', '8', '-15', '0'), '64 MiB of zeros, zlib L1')
    put('zeros64m.ldf12.raw', ldf(z64, 12), '64 MiB of zeros, libdeflate L12')
    # one byte repeated, alternating pairs
    put('ab-run16m.L9.raw', zfl(b'ab' * (8 << 20), '9', '9', '-15', '0'), "16 MiB of 'ab', zlib L9 ml9")
    # matches at the largest distances: 32768 back (zlib never, others do), and 32506..32768
    import random
    rnd = random.Random(7)
    blk = bytes(rnd.getrandbits(8) for _ in range(32768))
    put('maxdist.ldf12.raw', ldf(blk + blk + blk[:1000], 12), 'random 32 KiB then itself: distance 32768', 'libdeflate L12')
    # hand-made: a fixed block with one literal then a match of distance 32768 needs 32768 bytes first; use stored + fixed
    lit = bytes(rnd.getrandbits(8) for _ in range(32768))
    stored = bits([(0, 1), (0, 2)]) + struct.pack('<HH', 32768, 32768 ^ 0xffff) + lit
    # fixed block: length 258 (symbol 285 = 11000101, 8 bits reversed) at distance 32768 (code 29, 5 bits + 13 extra)
    def rev(v, k): return int('{:0{k}b}'.format(v, k=k)[::-1], 2)
    fixed = bits([(1, 1), (1, 2), (rev(0b11000101, 8), 8), (rev(29, 5), 5), (32768 - 24577, 13), (0, 7)])
    put('dist32768-258.raw', stored + fixed, 'stored 32768 B, then fixed: match 258 at distance 32768, end',
        'the farthest match deflate allows; zlib never makes it (MAX_DIST 32506)')
    # 258 written as 284+31 (allowed by inflaters, never by zlib)
    put('len258as284.raw', bits([(1, 1), (1, 2), (rev(0x30 + ord('x'), 8), 8), (rev(0b11000100, 8), 8), (31, 5), (0, 5), (0, 7)]),
        "fixed: literal 'x', then 258 as symbol 284 + extra 31 at distance 1, end", 'LEN_258_AS_284')
    # stored oddities: empty stored blocks, non-zero padding bits, a stored block split in 1-byte pieces, stored-only stream
    data = b'stored blocks, oddly cut.' * 10
    parts = []
    for i, ch in enumerate(data[:40]):
        parts.append(bits([(0, 1), (0, 2), (0b10101 if i % 2 else 0, 5)]) + struct.pack('<HH', 1, 0xfffe) + bytes([ch]))
    parts.append(bits([(0, 1), (0, 2), (0b11111, 5)]) + struct.pack('<HH', 0, 0xffff))
    parts.append(bits([(1, 1), (0, 2), (0, 5)]) + struct.pack('<HH', len(data) - 40, (len(data) - 40) ^ 0xffff) + data[40:])
    put('stored-1byte-pads.raw', b''.join(parts), '40 stored blocks of 1 byte with non-zero pad bits, an empty one, a final one')
    put('stored-only.L0.raw', zfl(bytes(range(256)) * 600, '0', '8', '-15', '0'), 'zlib level 0 (stored only), 150 KiB')
    put('empty.L6.z', zlib.compress(b'', 6), 'empty input, zlib L6 (one fixed block)')
    put('empty-fixed-blocks.raw', bits([(0, 1), (1, 2), (0, 7)] * 3 + [(1, 1), (1, 2), (0, 7)]),
        'three non-final empty fixed blocks then a final empty one', 'old zlib partial flush shape (pdfTeX)')
    # zlib framing oddities
    put('fdict.z', bytes([0x78, 0xbb]) + struct.pack('>I', 1) + zlib.compress(b'abc')[2:], 'FDICT set (preset dictionary id 1)',
        'must be NOT_TAKEN')
    good = zlib.compress(b'hello hello hello hello' * 100, 9)
    put('bad-adler.z', good[:-1] + bytes([good[-1] ^ 1]), 'zlib L9 with a wrong Adler-32')
    put('trailing.z', good + b'GARBAGE', 'zlib L9 with 7 bytes after the Adler-32')
    put('truncated.z', good[:len(good) // 2], 'zlib L9 cut in half', 'must fail with a position')
    flip = bytearray(good); flip[len(flip) // 3] ^= 0x10
    put('bitflip.z', bytes(flip), 'zlib L9 with one bit flipped')
    put('btype3.raw', bits([(1, 1), (3, 2), (0, 5)]) + b'\0' * 4, 'block type 3 (invalid)')
    c = zlib.compressobj(9, zlib.DEFLATED, 9)
    put('wbits9.L9.z', c.compress(b'window nine ' * 3000) + c.flush(), 'zlib L9 window 9 (header 18 xx)')
    print('hostile', write_manifest(out, rows))


# ---------------------------------------------------------------- zflow (M2)

ZFLOW_ZLIBS = [('new', 'zfl'), ('1.2.5', 'zfl-1.2.5'), ('1.2.3', 'zfl-1.2.3')]


def zflow_scripts(n):
    """flush and deflateParams scripts on n bytes: (name, level, memLevel, strategy, events)"""
    ev = lambda upto, step, what: ['%d:%s' % (i, what) for i in range(step, upto, step)]
    return [
        ('partial20', 6, 8, 0, ev(2000, 20, 'partial')),        # tiny blocks: _tr_align's second block in old zlibs
        ('partial97-L1', 1, 8, 0, ev(n, 97, 'partial')),
        ('partial4k', 6, 8, 0, ev(n, 4096, 'partial')),
        ('sync8k-L9', 9, 8, 0, ev(n, 8192, 'sync')),
        ('sync333-L3-ml5', 3, 5, 0, ev(20000, 333, 'sync')),
        ('full-third', 6, 8, 0, ['%d:full' % (n // 3), '%d:full' % (2 * n // 3)]),
        ('full-L1-many', 1, 7, 0, ev(n, 10000, 'full')),
        ('mixed', 6, 8, 0, ['0:sync', '%d:sync' % (n // 5), '%d:partial' % (2 * n // 5), '%d:full' % (3 * n // 5),
                            '%d:block' % (4 * n // 5)]),
        ('params6to1', 6, 8, 0, ['%d:params=1,0' % (n // 2)]),
        ('params9tofilt', 9, 8, 0, ['%d:params=9,1' % (n // 2)]),
        ('params6to9', 6, 8, 0, ['%d:params=9,0' % (n // 2)]),  # the same loop: no flush
        ('params1torle', 1, 8, 0, ['%d:params=1,3' % (n // 3)]),
        ('rle-sync', 6, 8, 3, ev(n, 5000, 'sync')),
        ('huff-partial', 6, 8, 2, ev(n, 3000, 'partial')),
        ('block-many', 6, 8, 0, ev(n, 7000, 'block')),
    ]


def do_zflow():
    """zlib 1.3.1 (zfl), 1.2.5 and 1.2.3 (zfl-1.2.5, zfl-1.2.3: built by build_tools.sh) with flushes and
    deflateParams on the first 120000 bytes of the raw samples: M2's flows, each zlib's flushes"""
    out = fresh('zflow'); rows = []
    src = os.path.join(CORPUS, 'raw', 'plain')
    for f in ['text', 'exe', 'bmp']:
        plain = open(os.path.join(src, f + '.bin'), 'rb').read()[:120000]
        p = os.path.join(out, '.in.' + f); open(p, 'wb').write(plain)
        for name, lv, ml, st, ev in zflow_scripts(len(plain)):
            for zv, exe in ZFLOW_ZLIBS:
                # zlib 1.2.3 has no Z_BLOCK for deflate
                if zv == '1.2.3' and any(e.endswith(':block') for e in ev): continue
                raw = subprocess.run([BIN + '/' + exe, p, str(lv), str(ml), '-15', str(st)] + ev,
                                     check=True, capture_output=True).stdout
                fn = '%s.%s.%s.raw' % (f, name, zv)
                open(os.path.join(out, fn), 'wb').write(raw)
                rows.append(dict(file=fn, kind='raw', origin='plain/%s.bin[:120000]' % f, encoder='zlib (zfl)',
                                 version='zlib 1.3.1' if zv == 'new' else 'zlib ' + zv,
                                 settings='L%d ml%d s%d w15 events %s' % (lv, ml, st, ' '.join(ev) if len(ev) <= 4
                                          else '%s .. (%d)' % (' '.join(ev[:3]), len(ev))), note=''))
        os.remove(p)
    print('zflow', write_manifest(out, rows))


def main():
    global JOBS
    args = sys.argv[1:]
    if '-j' in args:
        i = args.index('-j'); JOBS = int(args[i + 1]); del args[i:i + 2]
    versions()
    what = args[0] if args else 'all'
    for name, f in [('png', do_png), ('synth', do_synth), ('raw', do_raw), ('pda', do_pda), ('hostile', do_hostile),
                    ('zflow', do_zflow)]:
        if what in (name, 'all'):
            f()


if __name__ == '__main__':
    main()
