#!/usr/bin/env python3
"""The preflate harness (README.md): for corpus subsets, what PPA does today
and what preflate 0.3.4's reconstruction data costs, per stream; and the v2
.ppa hashes of the sets PPA must keep writing byte for byte.

    python3 tools/preflate/baseline.py streams SUBSET... [-j N] [--out DIR]
    python3 tools/preflate/baseline.py gate [SET...] [--out DIR]
    python3 tools/preflate/baseline.py summary [--out DIR] [--md FILE]

streams   SUBSET is a folder of $PF/corpus (png-zlib, png-nonzlib, png-synth,
          raw, pda, hostile). PNG-family files go through the real `ppa a`
          (sizes, .ppa sha256), `ppa info` (how many image streams went as
          bytes) and ppastreams (each stream: PPA's decode and zlib search);
          then each stream that inflates goes through preflate -s / -x, whose
          round trip is compared byte for byte. Writes DIR/SUBSET.files.tsv
          and DIR/SUBSET.streams.tsv.
gate      `ppa a` on whole sets (default: tests/png, sets corpus, generated,
          photos) with 8 threads, 1 thread, and the Pascal path (PPA_NOC=1),
          the .ppa sha256 of each: DIR/gate.tsv. This is the M1 hash gate.
summary   the tables of BASELINE.md from DIR's TSVs.

DIR defaults to $PF/m0/bench, the frozen M0 baseline (read-only): pass
--out for a new run. Every child runs under ulimit -v 6000000."""
import collections, datetime, json, os, re, resource, shutil, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pfcommon import *

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
JOBS = 4
OUT = os.path.join(PF, 'm0', 'bench')
PPA = os.path.join(BIN, 'ppa')
PNG_SUBSETS = ('png-zlib', 'png-nonzlib', 'png-synth')
PF_TIMEOUT = 600
VMEM = 6000000 * 1024


def limit():
    resource.setrlimit(resource.RLIMIT_AS, (VMEM, VMEM))


def sh(cmd, env=None, timeout=None, cwd=None):
    return subprocess.run(cmd, capture_output=True, env=env, timeout=timeout, preexec_fn=limit, cwd=cwd)


def tsv_write(path, cols, rows):
    with open(path, 'w') as f:
        f.write('\t'.join(cols) + '\n')
        for r in rows:
            f.write('\t'.join(str(r.get(c, '')) for c in cols) + '\n')


def tsv_read(path):
    with open(path) as f:
        head = f.readline().rstrip('\n').split('\t')
        return [dict(zip(head, l.rstrip('\n').split('\t'))) for l in f]


# ---------------------------------------------------------------- preflate on one stream

def run_preflate(stream_path, framing):
    """preflate 0.3.4 on one stream file (zlib framing stripped first): its
    diff size, the round trip, times and peak RSS"""
    r = dict(deflate_bytes='', plain_bytes='', pf_ok='', pf_diff='', pf_split_s='', pf_recon_s='', pf_rss_mb='')
    data = open(stream_path, 'rb').read()
    try:
        if framing == 'zlib':
            body, plain, _ = deflate_body(data)
        else:
            body, plain = raw_body(data)
    except Exception:
        r['pf_ok'] = 'not-inflatable'
        return r
    r['deflate_bytes'] = len(body); r['plain_bytes'] = len(plain)
    tmp = tempfile.mkdtemp(dir=os.path.join(PF, 'tmp'))
    try:
        f = os.path.join(tmp, 's')
        open(f, 'wb').write(body)
        t0 = time.time()
        try:
            p = subprocess.run(['/usr/bin/time', '-f', 'RSS %M', os.path.join(BIN, 'preflate'), '-s', f],
                               capture_output=True, timeout=PF_TIMEOUT, preexec_fn=limit)
        except subprocess.TimeoutExpired:
            r['pf_ok'] = 'timeout-split'; return r
        r['pf_split_s'] = '%.3f' % (time.time() - t0)
        m = re.search(rb'RSS (\d+)', p.stderr)
        if m: r['pf_rss_mb'] = '%.1f' % (int(m.group(1)) / 1024)
        if p.returncode != 0 or not os.path.exists(f + '.r'):
            r['pf_ok'] = 'split-failed'; return r
        r['pf_diff'] = os.path.getsize(f + '.r')
        t0 = time.time()
        try:
            p = subprocess.run([os.path.join(BIN, 'preflate'), '-x', f], capture_output=True, timeout=PF_TIMEOUT, preexec_fn=limit)
        except subprocess.TimeoutExpired:
            r['pf_ok'] = 'timeout-recon'; return r
        r['pf_recon_s'] = '%.3f' % (time.time() - t0)
        ok = os.path.exists(f + '.x') and open(f + '.x', 'rb').read() == body
        r['pf_ok'] = 'ok' if ok else 'roundtrip-differs'
        return r
    finally:
        shutil.rmtree(tmp)


def raw_body(data):
    o = __import__('zlib').decompressobj(-15)
    plain = o.decompress(data)
    if not o.eof:
        raise ValueError('deflate does not end')
    return data[:len(data) - len(o.unused_data)], plain


# ---------------------------------------------------------------- streams

def group_of(subset, file, man):
    """the encoder group a stream is reported under"""
    if subset == 'png-synth':
        return file.split('.')[1]                     # s05.oxipng-o2.png -> oxipng-o2
    if subset == 'raw':
        return file.split('.')[1]                     # text.ldf6.raw -> ldf6
    if subset == 'pda':
        return 'zlib' if man.get('encoder') == 'zlib' else 'not-zlib'
    if subset == 'hostile':
        return file.rsplit('.', 1)[0]
    return man.get('encoder', '?')


def do_streams(subset):
    folder = os.path.join(CORPUS, subset)
    man = {r['file']: r for r in read_manifest(folder)}
    files = sorted(man)
    os.makedirs(OUT, exist_ok=True); os.makedirs(os.path.join(PF, 'tmp'), exist_ok=True)
    work = os.path.join(os.path.dirname(OUT), 'work', subset)
    if os.path.isdir(work): shutil.rmtree(work)
    os.makedirs(work)
    paths = [os.path.join(folder, f) for f in files]
    frows = []
    streams = []   # (file, index, kind, framing, stream_bytes, ppa_plain, blocks, decode, zlib, stream path)
    if subset in PNG_SUBSETS:
        # real compression, one process per batch of files (8 threads, the default)
        pdir = os.path.join(work, 'ppa'); os.makedirs(pdir)
        a = {}
        for i in range(0, len(paths), 64):
            p = sh([PPA, 'a', '--json', '-q', '-o', pdir + '/', '--'] + paths[i:i + 64])
            for line in p.stdout.decode().splitlines():
                j = json.loads(line)
                if 'file' in j: a[os.path.basename(j['file'])] = j
        info = {}
        for i in range(0, len(paths), 64):
            p = sh([PPA, 'info', '--json', '--'] + paths[i:i + 64])
            for line in p.stdout.decode().splitlines():
                j = json.loads(line)
                if 'file' in j: info[os.path.basename(j['file'])] = j
        for f in files:
            j = a.get(f, {}); k = info.get(f, {}).get('ppa', {}).get('image_streams', {})
            out = j.get('output')
            frows.append(dict(subset=subset, file=f, group=group_of(subset, f, man[f]), bytes=os.path.getsize(os.path.join(folder, f)),
                              ppa_ok=j.get('ok', False), ppa_size=j.get('ppa_size', ''), stored=j.get('stored', ''),
                              info_size=info.get(f, {}).get('ppa', {}).get('ppa_size', ''),
                              as_bytes=k.get('bytes', ''), slow=k.get('slow_model', ''), fast=k.get('fast_model', ''),
                              static=k.get('static_model', ''), jpeg=k.get('JPEG_pja', ''),
                              ppa_sha256=sha256(out) if out and os.path.exists(out) else ''))
        tsv_write(os.path.join(OUT, subset + '.files.tsv'),
                  ['subset', 'file', 'group', 'bytes', 'ppa_ok', 'ppa_size', 'info_size', 'stored', 'as_bytes', 'slow', 'fast',
                   'static', 'jpeg', 'ppa_sha256'], frows)
        sdir = os.path.join(work, 'streams'); os.makedirs(sdir)
        for i in range(0, len(paths), 64):
            p = sh([os.path.join(BIN, 'ppastreams'), '-dump', sdir] + paths[i:i + 64])
            for line in p.stdout.decode().splitlines():
                c = line.split('\t')
                if c[1] == '-': continue
                f = os.path.basename(c[0])
                sp = os.path.join(sdir, '%s.%s.%s' % (f, c[1], 'raw' if c[3] == 'raw' else 'z'))
                streams.append((f, c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], sp))
    else:
        for i in range(0, len(paths), 256):
            p = sh([os.path.join(BIN, 'ppastreams'), '-stream'] + paths[i:i + 256])
            for line in p.stdout.decode().splitlines():
                c = line.split('\t')
                streams.append((os.path.basename(c[0]), c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[0]))

    def one(s):
        f, idx, kind, framing, sb, plain, blocks, dec, zl, sp = s
        r = dict(subset=subset, file=f, stream=idx, kind=kind, framing=framing, group=group_of(subset, f, man.get(f, {})),
                 stream_bytes=sb, ppa_plain=plain, blocks=blocks, ppa_decode=dec, ppa_zlib=zl)
        if dec.startswith('ok') or subset == 'hostile':
            r.update(run_preflate(sp, framing) if os.path.exists(sp) else dict(pf_ok='no-file'))
        else:
            r['pf_ok'] = 'not-decoded'
        return r
    with ThreadPoolExecutor(JOBS) as ex:
        srows = list(ex.map(one, streams))
    tsv_write(os.path.join(OUT, subset + '.streams.tsv'),
              ['subset', 'file', 'stream', 'kind', 'framing', 'group', 'stream_bytes', 'deflate_bytes', 'plain_bytes', 'ppa_plain', 'blocks',
               'ppa_decode', 'ppa_zlib', 'pf_ok', 'pf_diff', 'pf_split_s', 'pf_recon_s', 'pf_rss_mb'], srows)
    if subset in PNG_SUBSETS:
        shutil.rmtree(os.path.join(work, 'streams'))
    bad = [r for r in srows if r.get('pf_ok') not in ('ok', 'not-decoded', 'not-inflatable')]
    print('%s: %d files, %d streams, %d zlib-reproduced, preflate failures %d' %
          (subset, len(files), len(srows), sum(r['ppa_zlib'] != '-' for r in srows), len(bad)))


# ---------------------------------------------------------------- gate

GATE_SETS = {
    'tests-png': os.path.join(REPO, 'tests', 'png'),
    'sets-corpus': os.path.join(SETS, 'corpus'),
    'sets-generated': os.path.join(SETS, 'generated'),
    'sets-photos': os.path.join(SETS, 'photos'),
}
VARIANTS = [('c-th8', [], {}), ('c-th1', ['-th', '1'], {}), ('pas-th8', [], {'PPA_NOC': '1'})]


def do_gate(names):
    rows = []
    os.makedirs(OUT, exist_ok=True)
    for name in names or GATE_SETS:
        folder = GATE_SETS[name]
        files = sorted(os.path.join(folder, f) for f in os.listdir(folder) if os.path.isfile(os.path.join(folder, f)))
        per = collections.defaultdict(dict)
        for v, args, env in VARIANTS:
            d = os.path.join(os.path.dirname(OUT), 'work', 'gate', name, v)
            if os.path.isdir(d): shutil.rmtree(d)
            os.makedirs(d)
            t0 = time.time()
            p = sh([PPA, 'a', '--json', '-q', '-o', d + '/'] + args + ['--'] + files, env=dict(os.environ, **env))
            dt = time.time() - t0
            for line in p.stdout.decode().splitlines():
                j = json.loads(line)
                if 'file' not in j: continue
                f = os.path.basename(j['file'])
                out = j.get('output')
                per[f][v] = (j.get('ok'), j.get('ppa_size', ''), sha256(out) if out and os.path.exists(out) else '')
                per[f]['bytes'] = j.get('original_size', os.path.getsize(j['file']))
            print('  gate %s %s: %.1f s, exit %d' % (name, v, dt, p.returncode), flush=True)
        for f in sorted(per):
            r = dict(set=name, file=f, bytes=per[f].get('bytes', ''))
            for v, _, _ in VARIANTS:
                ok, size, h = per[f].get(v, (False, '', ''))
                r[v + '_size'] = size; r[v + '_sha256'] = h
            hs = {per[f].get(v, (0, 0, ''))[2] for v, _, _ in VARIANTS}
            r['identical'] = 'yes' if len(hs) == 1 and '' not in hs else 'NO'
            rows.append(r)
    cols = ['set', 'file', 'bytes'] + [v + s for v, _, _ in VARIANTS for s in ('_size', '_sha256')] + ['identical']
    old = [r for r in (tsv_read(os.path.join(OUT, 'gate.tsv')) if os.path.exists(os.path.join(OUT, 'gate.tsv')) else [])
           if r['set'] not in {r['set'] for r in rows}]
    tsv_write(os.path.join(OUT, 'gate.tsv'), cols, old + rows)
    for name in sorted({r['set'] for r in rows}):
        rs = [r for r in rows if r['set'] == name]
        print('%s: %d files, %d -> %d B, identical across variants: %d/%d' % (
            name, len(rs), sum(int(r['bytes']) for r in rs), sum(int(r['c-th8_size'] or 0) for r in rs),
            sum(r['identical'] == 'yes' for r in rs), len(rs)))


# ---------------------------------------------------------------- summary

def pct(a, b):
    return '%.2f' % (100.0 * a / b) if b else '-'


CREATORS = [('MS Office 2013+', r'(Microsoft|Office).*1[56]\.|Word 1[56]|Excel 1[56]|PowerPoint 1[56]|^ 1[56]\.'),
            ('MS Office 2007/2010', r'(Microsoft|Office).*1[24]\.|Word 1[24]|Excel 1[24]|PowerPoint 1[24]|^ 1[24]\.'),
            ('Quartz/macOS', r'Quartz|macOS|Mac OS'), ('SAMBox', r'SAMBox'), ('Aspose', r'Aspose'),
            ('TCPDF/FPDF', r'TCPDF|FPDF'), ('FOP', r'FOP'), ('calibre', r'calibre'), ('PDFium', r'PDFium'), ('pdfTeX', r'pdfTeX|TeX'), ('Skia/Chrome', r'Skia|Chrom'), ('cairo/Firefox', r'cairo|Firefox'),
            ('Adobe', r'Adobe|Acrobat|Distiller'), ('LibreOffice/OOo', r'LibreOffice|OpenOffice|StarOffice|OOo'),
            ('iText', r'iText|itext'), ('Ghostscript', r'Ghostscript|GPL'), ('Microsoft (other)', r'Microsoft')]


def creator_family(note):
    c = note.split(';')[0].replace('creator=', '')
    for name, pat in CREATORS:
        if re.search(pat, c):
            return name
    return 'other' if c != 'unknown' else 'unknown'


MARK = '<!-- generated by baseline.py summary: everything below this line -->'


def do_summary(md):
    L = []
    w = L.append
    w('# preflate harness baseline (M0)\n')
    w('Measured %s at PPA commit `%s` (ppa 0.2.1, codec stream version 2) with preflate 0.3.4 (precomp 0.4.7 contrib), '
      'by `tools/preflate/baseline.py`. Corpus: `$PF/corpus` (`tools/preflate/mkcorpus.py`); tool versions: '
      '`$PF/tools/VERSIONS.tsv`; raw TSVs: `$PF/m0/bench/`.\n' % (
          datetime.date.today().isoformat(), subprocess.run(['git', '-C', REPO, 'rev-parse', '--short', 'HEAD'],
                                                             capture_output=True, text=True).stdout.strip()))
    gate = os.path.join(OUT, 'gate.tsv')
    if os.path.exists(gate):
        rows = tsv_read(gate)
        w('## v2 `.ppa` hash gate (M1: none of these may change)\n')
        w('Real `ppa a` (not `ppa info` estimates). Each file was compressed three ways, C path with 8 threads and with 1, '
          'and the Pascal path (`PPA_NOC=1`); "identical" counts files whose three `.ppa` are the same bytes. '
          'Per-file sizes and sha256 are in `gate.tsv`.\n')
        w('| set | files | original B | `.ppa` B | ratio | identical |')
        w('|---|---:|---:|---:|---:|---:|')
        for name in sorted({r['set'] for r in rows}):
            rs = [r for r in rows if r['set'] == name]
            a = sum(int(r['bytes']) for r in rs); b = sum(int(r['c-th8_size'] or 0) for r in rs)
            w('| %s | %d | %s | %s | %s%% | %d/%d |' % (name, len(rs), f'{a:,}', f'{b:,}', pct(b, a),
                                                    sum(r['identical'] == 'yes' for r in rs), len(rs)))
        w('')
    for subset in ['png-zlib', 'png-nonzlib', 'png-synth', 'raw', 'pda', 'hostile']:
        sp = os.path.join(OUT, subset + '.streams.tsv')
        if not os.path.exists(sp): continue
        srows = tsv_read(sp)
        fp = os.path.join(OUT, subset + '.files.tsv')
        frows = tsv_read(fp) if os.path.exists(fp) else []
        w('## %s\n' % subset)
        if frows:
            a = sum(int(r['bytes']) for r in frows); b = sum(int(r['ppa_size'] or 0) for r in frows)
            nb = sum(int(r['as_bytes'] or 0) for r in frows)
            diff = sum(1 for r in frows if r['info_size'] and r['ppa_size'] and r['info_size'] != r['ppa_size'])
            w('%d files, %s B -> `ppa a` %s B (%s%%); %d image streams kept as bytes; `ppa info` size differs from `ppa a` on %d files.\n' % (
                len(frows), f'{a:,}', f'{b:,}', pct(b, a), nb, diff))
        g = collections.OrderedDict()
        for r in sorted(srows, key=lambda r: r['group']):
            g.setdefault(r['group'], []).append(r)
        asb = collections.Counter()
        for r in frows:
            asb[r['group']] += int(r['as_bytes'] or 0)
        w('| group | streams | deflate B | plain B | zlib-reproduced (PPA v2) | PPA as bytes | preflate ok | preflate diff B | diff % deflate | diff % plain | split MB/s |')
        w('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
        tot = collections.Counter()
        for k, rs in g.items():
            ok = [r for r in rs if r['pf_ok'] == 'ok']
            d = sum(int(r['deflate_bytes']) for r in ok); p = sum(int(r['plain_bytes']) for r in ok)
            dd = sum(int(r['pf_diff']) for r in ok); t = sum(float(r['pf_split_s']) for r in ok)
            zr = sum(r['ppa_zlib'] != '-' for r in rs)
            tot.update(n=len(rs), d=d, p=p, dd=dd, zr=zr, ok=len(ok))
            tot.update(asb=asb[k])
            w('| %s | %d | %s | %s | %d | %s | %d | %s | %s | %s | %s |' % (k, len(rs), f'{d:,}', f'{p:,}', zr, asb[k] if frows else '-', len(ok), f'{dd:,}',
                                                                 pct(dd, d), pct(dd, p), '%.1f' % (p / t / 1e6) if t else '-'))
        w('| **total** | %d | %s | %s | %d | %s | %d | %s | %s | %s | |' % (tot['n'], f"{tot['d']:,}", f"{tot['p']:,}", tot['zr'], tot['asb'] if frows else '-', tot['ok'],
                                                                  f"{tot['dd']:,}", pct(tot['dd'], tot['d']), pct(tot['dd'], tot['p'])))
        if subset == 'pda':
            man = {r['file']: r for r in read_manifest(os.path.join(CORPUS, 'pda'))}
            cg = collections.defaultdict(list)
            for r in srows:
                cg[creator_family(man[r['file']]['note'])].append(r)
            w('\nBy creator (families; `pda/MANIFEST.tsv` has the full creator string):\n')
            w('| creator | streams | not zlib (census3) | deflate B | zlib-reproduced (PPA v2) | preflate diff B | diff % deflate |')
            w('|---|---:|---:|---:|---:|---:|---:|')
            for k, rs in sorted(cg.items(), key=lambda kv: -sum(int(r['deflate_bytes'] or 0) for r in kv[1])):
                ok = [r for r in rs if r['pf_ok'] == 'ok']
                d = sum(int(r['deflate_bytes']) for r in ok); dd = sum(int(r['pf_diff']) for r in ok)
                w('| %s | %d | %d | %s | %d | %s | %s |' % (k, len(rs), sum(r['group'] == 'not-zlib' for r in rs), f'{d:,}',
                                                       sum(r['ppa_zlib'] != '-' for r in rs), f'{dd:,}', pct(dd, d)))
        bad = collections.Counter(r['pf_ok'] for r in srows if r['pf_ok'] != 'ok')
        if bad:
            w('\nNot through preflate: ' + ', '.join('%s %d' % kv for kv in sorted(bad.items())) + '.')
        w('')
    text = '\n'.join(L) + '\n'
    open(os.path.join(OUT, 'summary.md'), 'w').write(text)
    if md:
        head = ''
        if os.path.exists(md) and MARK in open(md).read():
            head = open(md).read().split(MARK)[0]
        open(md, 'w').write(head + MARK + '\n\n' + text)
    print(text)


def main():
    global JOBS, OUT
    a = sys.argv[1:]
    if '-j' in a:
        i = a.index('-j'); JOBS = int(a[i + 1]); del a[i:i + 2]
    md = None
    if '--out' in a:
        i = a.index('--out'); OUT = a[i + 1]; del a[i:i + 2]
    if '--md' in a:
        i = a.index('--md'); md = a[i + 1]; del a[i:i + 2]
    cmd, rest = a[0], a[1:]
    if cmd == 'streams':
        for s in rest: do_streams(s)
    elif cmd == 'gate':
        do_gate(rest)
    elif cmd == 'summary':
        do_summary(md)
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main()
